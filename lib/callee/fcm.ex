defmodule Callee.FCM do
  @moduledoc """
  Firebase Cloud Messaging (HTTP v1) for the Android app.

  A high-priority *data* message wakes the phone even in deep sleep or after
  the app was killed; the app then shows its full-screen ringing screen.
  Enabled when FCM_SERVICE_ACCOUNT (path to the service-account JSON, or the
  JSON itself, or base64 of it) is configured; otherwise every call is a no-op.
  """
  require Logger
  import Ecto.Query
  alias Callee.Repo

  defmodule DeviceToken do
    use Ecto.Schema

    schema "device_tokens" do
      field :owner_type, :string
      field :owner_id, :integer
      field :token, :string
      field :platform, :string, default: "android"
      timestamps(type: :utc_datetime)
    end
  end

  @scope "https://www.googleapis.com/auth/firebase.messaging"

  ## Tokens

  def register({type, id}, token, platform \\ "android") when is_binary(token) and token != "" do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      DeviceToken,
      [
        %{
          owner_type: to_string(type),
          owner_id: id,
          token: token,
          platform: platform,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:owner_type, :owner_id, :platform, :updated_at]},
      conflict_target: :token
    )

    :ok
  end

  def unregister(token), do: Repo.delete_all(from d in DeviceToken, where: d.token == ^token)

  def tokens({type, id}),
    do:
      Repo.all(
        from d in DeviceToken,
          where: d.owner_type == ^to_string(type) and d.owner_id == ^id,
          select: d.token
      )

  ## Sending

  def enabled?, do: credentials() != nil

  @doc "Send a data message to every device of `party`. Returns {:ok, delivered_count}."
  def send_to(party, data, opts \\ []) do
    with creds when is_map(creds) <- credentials(),
         [_ | _] = toks <- tokens(party),
         {:ok, access} <- access_token(creds) do
      sent =
        Enum.count(toks, fn tok ->
          case post(creds["project_id"], access, message(tok, data, opts)) do
            :ok ->
              true

            {:gone, _} ->
              unregister(tok)
              false

            other ->
              Logger.warning("fcm send failed: #{inspect(other)}")
              false
          end
        end)

      {:ok, sent}
    else
      _ -> {:ok, 0}
    end
  rescue
    e ->
      Logger.error("fcm error: #{Exception.message(e)}")
      {:ok, 0}
  end

  defp message(token, data, opts) do
    %{
      message: %{
        token: token,
        # data-only so the app always handles it (also when killed)
        data: Map.new(data, fn {k, v} -> {to_string(k), to_string(v)} end),
        android: %{priority: "HIGH", ttl: "#{Keyword.get(opts, :ttl, 45)}s"}
      }
    }
  end

  defp post(project, access, body) do
    base = Application.get_env(:callee, :fcm_base_url, "https://fcm.googleapis.com")
    url = "#{base}/v1/projects/#{project}/messages:send"
    headers = [{"authorization", "Bearer " <> access}, {"content-type", "application/json"}]

    case :hackney.request(:post, url, headers, Jason.encode!(body), [
           :with_body,
           recv_timeout: 10_000
         ]) do
      {:ok, 200, _, _} ->
        :ok

      {:ok, s, _, b} when s in [404] ->
        {:gone, b}

      {:ok, 400, _, b} ->
        if b =~ "INVALID_ARGUMENT" and b =~ "registration", do: {:gone, b}, else: {:error, 400, b}

      {:ok, s, _, b} ->
        if b =~ "UNREGISTERED", do: {:gone, b}, else: {:error, s, b}

      err ->
        err
    end
  end

  ## Service-account OAuth (JWT bearer grant), cached ~55 min

  defp access_token(creds) do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      {tok, exp} when is_binary(tok) ->
        if System.system_time(:second) < exp, do: {:ok, tok}, else: fetch_token(creds)

      _ ->
        fetch_token(creds)
    end
  end

  defp fetch_token(creds) do
    now = System.system_time(:second)

    claims = %{
      iss: creds["client_email"],
      scope: @scope,
      aud: creds["token_uri"] || "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600
    }

    jwt = sign_rs256(claims, creds["private_key"])

    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    case :hackney.request(
           :post,
           claims.aud,
           [{"content-type", "application/x-www-form-urlencoded"}],
           body,
           [:with_body]
         ) do
      {:ok, 200, _, b} ->
        %{"access_token" => tok, "expires_in" => ttl} = Jason.decode!(b)
        :persistent_term.put({__MODULE__, :token}, {tok, now + ttl - 300})
        {:ok, tok}

      other ->
        Logger.error("fcm oauth failed: #{inspect(other)}")
        {:error, :oauth}
    end
  end

  @doc false
  def sign_rs256(claims, pem) do
    b64 = &Base.url_encode64(&1, padding: false)
    input = b64.(Jason.encode!(%{alg: "RS256", typ: "JWT"})) <> "." <> b64.(Jason.encode!(claims))
    [entry] = :public_key.pem_decode(pem)
    key = :public_key.pem_entry_decode(entry)
    input <> "." <> b64.(:public_key.sign(input, :sha256, key))
  end

  @doc false
  def reset_cache do
    :persistent_term.erase({__MODULE__, :creds})
    :persistent_term.erase({__MODULE__, :token})
  end

  defp credentials do
    case :persistent_term.get({__MODULE__, :creds}, :unset) do
      :unset ->
        c = load_credentials(Application.get_env(:callee, :fcm_service_account))
        :persistent_term.put({__MODULE__, :creds}, c)
        c

      c ->
        c
    end
  end

  defp load_credentials(v) when v in [nil, ""], do: nil

  defp load_credentials(v) do
    raw =
      cond do
        String.starts_with?(String.trim_leading(v), "{") -> v
        File.exists?(v) -> File.read!(v)
        true -> Base.decode64!(v)
      end

    case Jason.decode!(raw) do
      %{"private_key" => _, "client_email" => _, "project_id" => _} = c -> c
      _ -> nil
    end
  rescue
    e ->
      Logger.error("FCM_SERVICE_ACCOUNT unreadable: #{Exception.message(e)}")
      nil
  end
end
