defmodule Callee.FCMTest do
  @moduledoc "FCM HTTP v1 flow against a local stand-in for Google's endpoints."
  use Callee.DataCase, async: false
  import Plug.Conn
  alias Callee.{Accounts, FCM}

  defmodule Stub do
    use Plug.Router
    plug :match
    plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason
    plug :dispatch

    post "/token" do
      send(:fcm_test, {:oauth, conn.body_params})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"access_token":"ya29.test","expires_in":3600}))
    end

    post "/v1/projects/:project/messages:send" do
      send(:fcm_test, {:send, project, get_req_header(conn, "authorization"), conn.body_params})
      tok = get_in(conn.body_params, ["message", "token"])

      if tok == "dead-token",
        do:
          send_resp(
            conn,
            404,
            ~s({"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}})
          ),
        else: send_resp(conn, 200, ~s({"name":"projects/p/messages/1"}))
    end
  end

  setup do
    Process.register(self(), :fcm_test)
    port = Enum.random(41_000..49_000)
    {:ok, _} = start_supervised({Bandit, plug: Stub, port: port, startup_log: false})

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    creds = %{
      "type" => "service_account",
      "project_id" => "callee-test",
      "client_email" => "push@callee-test.iam.gserviceaccount.com",
      "private_key" => pem,
      "token_uri" => "http://127.0.0.1:#{port}/token"
    }

    Application.put_env(:callee, :fcm_service_account, Jason.encode!(creds))
    Application.put_env(:callee, :fcm_base_url, "http://127.0.0.1:#{port}")
    FCM.reset_cache()

    on_exit(fn ->
      Application.delete_env(:callee, :fcm_service_account)
      Application.delete_env(:callee, :fcm_base_url)
      FCM.reset_cache()
    end)

    exp = DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)

    {:ok, t} =
      Accounts.create_tenant(%{
        name: "Org",
        username: "fcmorg",
        password: "password1",
        expires_at: exp
      })

    {:ok, c, _} =
      Accounts.add_contact(t, %{"name" => "P", "mobile" => "7333333333", "password" => "pw1234"})

    %{key: key, client: {:client, c.client_id}}
  end

  test "sends a high-priority data message with a valid service-account JWT", %{
    key: key,
    client: client
  } do
    :ok = FCM.register(client, "good-token")

    assert {:ok, 1} =
             FCM.send_to(client, %{
               type: "incoming_call",
               call_id: "c1",
               name: "Org",
               label: "Audio call"
             })

    assert_receive {:oauth,
                    %{
                      "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
                      "assertion" => jwt
                    }}

    [h, c, sig] = String.split(jwt, ".")
    pub = {:RSAPublicKey, elem(key, 2), elem(key, 3)}

    assert :public_key.verify(
             h <> "." <> c,
             :sha256,
             Base.url_decode64!(sig, padding: false),
             pub
           )

    claims = c |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["scope"] == "https://www.googleapis.com/auth/firebase.messaging"
    assert claims["iss"] == "push@callee-test.iam.gserviceaccount.com"

    assert_receive {:send, "callee-test", ["Bearer ya29.test"], %{"message" => msg}}
    assert msg["token"] == "good-token"
    assert msg["android"] == %{"priority" => "HIGH", "ttl" => "45s"}

    assert msg["data"] == %{
             "type" => "incoming_call",
             "call_id" => "c1",
             "name" => "Org",
             "label" => "Audio call"
           }

    refute Map.has_key?(msg, "notification")

    # access token is cached
    assert {:ok, 1} = FCM.send_to(client, %{type: "call_cancel", call_id: "c1"})
    refute_receive {:oauth, _}, 100
  end

  test "dead tokens are removed", %{client: client} do
    :ok = FCM.register(client, "dead-token")
    :ok = FCM.register(client, "good-token")
    assert {:ok, 1} = FCM.send_to(client, %{type: "incoming_call", call_id: "c2"})
    assert FCM.tokens(client) == ["good-token"]
  end

  test "incoming-call push goes out over FCM", %{client: client} do
    :ok = FCM.register(client, "good-token")
    {:ok, n} = Callee.Push.notify_incoming(client, %{call_id: "c3", from: %{name: "Org"}})
    assert n >= 1

    assert_receive {:send, _, _,
                    %{"message" => %{"data" => %{"type" => "incoming_call", "call_id" => "c3"}}}},
                   2_000
  end
end
