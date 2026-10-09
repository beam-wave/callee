defmodule CalleeWeb.Auth do
  @moduledoc """
  Session auth for the three roles. One role per browser session:
  session["role"] in "admin" | "tenant" | "client", session["uid"] = id.
  """
  import Plug.Conn
  import Phoenix.Controller
  use CalleeWeb, :verified_routes
  alias Callee.Accounts
  alias Callee.Accounts.Tenant

  @salt "user socket"

  def log_in(conn, role, id) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:role, role)
    |> put_session(:uid, id)
  end

  def log_out(conn), do: conn |> configure_session(drop: true)

  def load_user("admin", id), do: Accounts.get_admin(id)

  def load_user("tenant", id),
    do:
      with(
        %Tenant{} = t <- Accounts.get_tenant(id),
        true <- Tenant.active?(t),
        do: t,
        else: (_ -> nil)
      )

  def load_user("client", id), do: Accounts.get_client(id)
  def load_user(_, _), do: nil

  def home_path("admin"), do: ~p"/admin"
  def home_path("tenant"), do: ~p"/tenant"
  def home_path("client"), do: ~p"/app"

  ## Plugs

  def fetch_current(conn, _opts) do
    role = get_session(conn, :role)
    user = role && load_user(role, get_session(conn, :uid))

    if role && !user do
      conn |> clear_session() |> assign(:current_user, nil) |> assign(:current_role, nil)
    else
      conn |> assign(:current_user, user) |> assign(:current_role, user && role)
    end
  end

  def require_role(conn, role) do
    if conn.assigns[:current_role] == role do
      conn
    else
      login = if role == "client", do: ~p"/login", else: "/#{role}/login"

      conn
      |> put_flash(:error, "Please sign in.")
      |> redirect(to: login)
      |> halt()
    end
  end

  def redirect_if_signed_in(conn, _opts) do
    if role = conn.assigns[:current_role] do
      to =
        case {role, conn.params["tab"]} do
          {"tenant", "calls"} -> ~p"/tenant/calls"
          {"client", "calls"} -> ~p"/app/calls"
          _ -> home_path(role)
        end

      # keep ?answer= / ?call= from the Android app's call notification
      rest = conn.query_params |> Map.delete("tab") |> URI.encode_query()
      to = if rest != "", do: to <> "?" <> rest, else: to
      conn |> redirect(to: to) |> halt()
    else
      conn
    end
  end

  ## LiveView

  def on_mount(role, _params, session, socket) do
    user = session["role"] == role && load_user(role, session["uid"])

    if user do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_user, user)
       |> Phoenix.Component.assign(:current_role, role)}
    else
      {:halt,
       Phoenix.LiveView.redirect(socket,
         to: if(role == "client", do: "/login", else: "/#{role}/login")
       )}
    end
  end

  ## Socket token (tenant/client only — they are the callers)

  def socket_token(role, id), do: Phoenix.Token.sign(CalleeWeb.Endpoint, @salt, {role, id})

  def verify_socket_token(token),
    do: Phoenix.Token.verify(CalleeWeb.Endpoint, @salt, token, max_age: 90 * 86_400)
end
