defmodule Callee.Push do
  @moduledoc """
  Web Push (RFC 8030) with aes128gcm payload encryption (RFC 8291) and VAPID (RFC 8292).

  Wakes the service worker when the app tab is closed/backgrounded so the user
  sees an "Incoming call" notification. VAPID keys come from env
  (VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY) or are generated once and stored in
  the `settings` table.
  """
  require Logger
  import Ecto.Query
  alias Callee.Repo

  defmodule Subscription do
    use Ecto.Schema

    schema "push_subscriptions" do
      field :owner_type, :string
      field :owner_id, :integer
      field :endpoint, :string
      field :p256dh, :string
      field :auth, :string
      timestamps(type: :utc_datetime)
    end
  end

  ## Subscriptions

  def subscribe({type, id}, %{"endpoint" => ep, "keys" => %{"p256dh" => p, "auth" => a}}) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      Subscription,
      [
        %{
          owner_type: to_string(type),
          owner_id: id,
          endpoint: ep,
          p256dh: p,
          auth: a,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:owner_type, :owner_id, :p256dh, :auth, :updated_at]},
      conflict_target: :endpoint
    )

    :ok
  end

  def subscribe(_, _), do: {:error, :invalid}

  def unsubscribe(endpoint),
    do: Repo.delete_all(from s in Subscription, where: s.endpoint == ^endpoint)

  ## Notifications

  @doc "Tell the Android app a call ended/was answered elsewhere so it stops ringing."
  def notify_cancel(party, call_id) do
    Callee.FCM.send_to(party, %{type: "call_cancel", call_id: call_id}, ttl: 60)
  end

  def notify_incoming(party, %{call_id: id, from: from} = payload) do
    label =
      case payload[:group] do
        %{name: n} when is_binary(n) and n != "" -> n
        %{} -> "Group call"
        _ -> "Audio call"
      end

    {:ok, n_fcm} =
      Callee.FCM.send_to(
        party,
        %{type: "incoming_call", call_id: id, name: from.name, label: label},
        ttl: 45
      )

    {:ok, n_web} = do_notify_incoming(party, id, from)
    {:ok, n_fcm + n_web}
  end

  defp do_notify_incoming(party, id, from) do
    send_to(
      party,
      %{
        type: "incoming_call",
        call_id: id,
        title: "Incoming call",
        body: "#{from.name} is calling you",
        tag: "call-#{id}"
      },
      ttl: 45
    )
  end

  def notify_missed(party, %{call_id: id, from: from}) do
    send_to(
      party,
      %{
        type: "missed_call",
        call_id: id,
        title: "Missed call",
        body: "You missed a call from #{from.name}",
        tag: "call-#{id}"
      },
      ttl: 86_400,
      urgency: "normal"
    )
  end

  def send_to(party, payload, opts \\ []) do
    if Application.get_env(:callee, :push_enabled, true),
      do: do_send(party, payload, opts),
      else: {:ok, 0}
  end

  defp do_send({type, id}, payload, opts) do
    subs =
      Repo.all(
        from s in Subscription, where: s.owner_type == ^to_string(type) and s.owner_id == ^id
      )

    json = Jason.encode!(payload)

    # Returns how many subscriptions the push services accepted (2xx).
    accepted =
      Enum.count(subs, fn sub ->
        case deliver(sub, json, opts) do
          {:ok, status} when status in 200..299 ->
            true

          {:ok, status} when status in [404, 410] ->
            Repo.delete(sub)
            false

          other ->
            Logger.warning("web push failed #{inspect(other)}")
            false
        end
      end)

    {:ok, accepted}
  rescue
    e ->
      Logger.error("web push error: #{Exception.message(e)}")
      {:ok, 0}
  end

  defp deliver(sub, json, opts) do
    {pub, priv} = vapid_keys()
    body = encrypt(json, b64d(sub.p256dh), b64d(sub.auth))
    %URI{scheme: s, host: h, port: p} = URI.parse(sub.endpoint)
    aud = if p in [80, 443], do: "#{s}://#{h}", else: "#{s}://#{h}:#{p}"
    jwt = vapid_jwt(aud, priv)

    headers = [
      {"TTL", to_string(Keyword.get(opts, :ttl, 60))},
      {"Urgency", Keyword.get(opts, :urgency, "high")},
      {"Content-Encoding", "aes128gcm"},
      {"Content-Type", "application/octet-stream"},
      {"Authorization", "vapid t=#{jwt}, k=#{pub}"}
    ]

    case :hackney.request(:post, sub.endpoint, headers, body, [:with_body, recv_timeout: 10_000]) do
      {:ok, status, _h, _b} -> {:ok, status}
      err -> err
    end
  end

  ## RFC 8291 aes128gcm

  @doc false
  def encrypt(plaintext, ua_public, auth_secret) do
    {as_public, as_private} = :crypto.generate_key(:ecdh, :prime256v1)
    ecdh = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)
    salt = :crypto.strong_rand_bytes(16)

    prk_key = hmac(auth_secret, ecdh)
    ikm = hmac(prk_key, "WebPush: info" <> <<0>> <> ua_public <> as_public <> <<1>>)
    prk = hmac(salt, ikm)
    <<cek::binary-16, _::binary>> = hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)
    <<nonce::binary-12, _::binary>> = hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>)

    {ct, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, plaintext <> <<2>>, "", true)

    salt <> <<4096::32, 65::8>> <> as_public <> ct <> tag
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  ## VAPID (RFC 8292)

  @doc false
  def __jwt_for_test__(aud), do: vapid_jwt(aud, elem(vapid_keys(), 1))

  defp vapid_jwt(aud, priv_b64) do
    header = b64e(Jason.encode!(%{typ: "JWT", alg: "ES256"}))
    exp = System.system_time(:second) + 12 * 3600
    sub = Application.get_env(:callee, :vapid_subject, "mailto:admin@example.com")
    claims = b64e(Jason.encode!(%{aud: aud, exp: exp, sub: sub}))
    input = header <> "." <> claims
    der = :crypto.sign(:ecdsa, :sha256, input, [b64d(priv_b64), :prime256v1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64e(<<r::unsigned-big-256, s::unsigned-big-256>>)
  end

  @doc "Returns {public_b64url, private_b64url}; generated + persisted on first use."
  def vapid_keys do
    case :persistent_term.get({__MODULE__, :vapid}, nil) do
      nil ->
        keys = load_or_create_keys()
        :persistent_term.put({__MODULE__, :vapid}, keys)
        keys

      keys ->
        keys
    end
  end

  def public_key, do: vapid_keys() |> elem(0)

  defp load_or_create_keys do
    env_pub = Application.get_env(:callee, :vapid_public_key)
    env_priv = Application.get_env(:callee, :vapid_private_key)

    if is_binary(env_pub) and env_pub != "" and is_binary(env_priv) and env_priv != "" do
      {env_pub, env_priv}
    else
      case {Callee.Settings.get("vapid_public"), Callee.Settings.get("vapid_private")} do
        {pub, priv} when is_binary(pub) and is_binary(priv) ->
          {pub, priv}

        _ ->
          {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)
          Callee.Settings.put_new("vapid_public", b64e(pub))
          Callee.Settings.put_new("vapid_private", b64e(priv))
          # Re-read in case another node won the race.
          {Callee.Settings.get("vapid_public"), Callee.Settings.get("vapid_private")}
      end
    end
  end

  defp b64e(bin), do: Base.url_encode64(bin, padding: false)
  defp b64d(str), do: Base.url_decode64!(String.trim_trailing(str, "="), padding: false)
end
