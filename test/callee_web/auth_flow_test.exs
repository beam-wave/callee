defmodule CalleeWeb.AuthFlowTest do
  use CalleeWeb.ConnCase, async: true
  alias Callee.Accounts

  test "role pages require login", %{conn: conn} do
    assert redirected_to(get(conn, "/admin")) == "/admin/login"
    assert redirected_to(get(conn, "/tenant")) == "/tenant/login"
    assert redirected_to(get(conn, "/app")) == "/login"
  end

  test "tenant can't log in after expiry", %{conn: conn} do
    {:ok, _} =
      Accounts.create_tenant(%{
        name: "X",
        username: "old",
        password: "password1",
        expires_at: ~U[2020-01-01 00:00:00Z]
      })

    conn = post(conn, "/tenant/login", %{"login" => %{"id" => "old", "password" => "password1"}})
    assert html_response(conn, 200) =~ "expired"
  end

  test "client login lands on /app and gets a call token", %{conn: conn} do
    exp = DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

    {:ok, t} =
      Accounts.create_tenant(%{
        name: "T",
        username: "ten3",
        password: "password1",
        expires_at: exp
      })

    {:ok, _, _} =
      Accounts.add_contact(t, %{"name" => "Bob", "mobile" => "5550001111", "password" => "pw1234"})

    conn = post(conn, "/login", %{"login" => %{"id" => "555-000-1111", "password" => "pw1234"}})
    assert redirected_to(conn) == "/app"
    html = conn |> recycle() |> get("/app") |> html_response(200)
    assert html =~ ~s(name="call-token")
    assert html =~ "T"
  end

  test "pages render for each role with pagination params", %{conn: conn} do
    exp = DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

    {:ok, t} =
      Accounts.create_tenant(%{
        name: "Shop",
        username: "shop1",
        password: "password1",
        expires_at: exp
      })

    {:ok, _, _} =
      Accounts.add_contact(t, %{"name" => "Zed", "mobile" => "5551112222", "password" => "pw1234"})

    tconn =
      post(conn, "/tenant/login", %{"login" => %{"id" => "shop1", "password" => "password1"}})

    for path <- ["/tenant?page=2&q=z", "/tenant/calls?filter=missed", "/tenant/settings"] do
      assert tconn |> recycle() |> get(path) |> html_response(200) =~ "Callee"
    end

    cconn =
      build_conn()
      |> post("/login", %{"login" => %{"id" => "5551112222", "password" => "pw1234"}})

    for path <- ["/app", "/app/calls?filter=outgoing", "/app/settings"] do
      assert cconn |> recycle() |> get(path) |> html_response(200) =~ "Callee"
    end

    assert redirected_to(cconn |> recycle() |> get("/login?tab=calls")) == "/app/calls"
  end
end
