defmodule CalleeWeb.DeviceApiTest do
  use CalleeWeb.ConnCase, async: true
  alias Callee.{Accounts, FCM}

  setup do
    exp = DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)

    {:ok, t} =
      Accounts.create_tenant(%{
        name: "Org",
        username: "apiorg",
        password: "password1",
        expires_at: exp
      })

    {:ok, c, _} =
      Accounts.add_contact(t, %{"name" => "P", "mobile" => "7444444444", "password" => "pw1234"})

    %{token: CalleeWeb.Auth.socket_token("client", c.client_id), client: {:client, c.client_id}}
  end

  test "registers an FCM token with the bearer socket token", %{
    conn: conn,
    token: token,
    client: client
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/devices", %{token: "fcm-abc"})

    assert %{"ok" => true} = json_response(conn, 200)
    assert FCM.tokens(client) == ["fcm-abc"]
  end

  test "rejects missing or bad tokens", %{conn: conn} do
    assert conn |> post("/api/devices", %{token: "x"}) |> json_response(401)

    assert build_conn()
           |> put_req_header("authorization", "Bearer nope")
           |> post("/api/devices", %{token: "x"})
           |> json_response(401)
  end
end
