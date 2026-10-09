defmodule CalleeWeb.SessionController do
  use CalleeWeb, :controller
  alias Callee.Accounts
  alias CalleeWeb.Auth

  def home(conn, _), do: redirect(conn, to: ~p"/login")

  def new(conn, _params), do: render_form(conn, role(conn))

  def create(conn, %{"login" => %{"id" => ident, "password" => pw}}) do
    role = role(conn)

    result =
      case role do
        "admin" -> Accounts.authenticate_admin(ident, pw)
        "tenant" -> Accounts.authenticate_tenant(ident, pw)
        "client" -> Accounts.authenticate_client(ident, pw)
      end

    case result do
      {:ok, user} ->
        conn |> Auth.log_in(role, user.id) |> redirect(to: Auth.home_path(role))

      {:error, :inactive} ->
        conn |> put_flash(:error, "This account has expired or is disabled.") |> render_form(role)

      _ ->
        conn |> put_flash(:error, "Invalid credentials.") |> render_form(role)
    end
  end

  def delete(conn, _) do
    role = get_session(conn, :role)
    to = if role in ["admin", "tenant"], do: "/#{role}/login", else: ~p"/login"
    conn |> Auth.log_out() |> redirect(to: to)
  end

  defp role(conn), do: role_from_path(conn)

  defp role_from_path(%{path_info: ["admin" | _]}), do: "admin"
  defp role_from_path(%{path_info: ["tenant" | _]}), do: "tenant"
  defp role_from_path(_), do: "client"

  defp render_form(conn, role) do
    {title, label, type} =
      case role do
        "admin" -> {"Admin sign in", "Username", "text"}
        "tenant" -> {"Tenant sign in", "Username", "text"}
        "client" -> {"Sign in", "Mobile number", "tel"}
      end

    action = if role == "client", do: ~p"/login", else: "/#{role}/login"

    render(conn, :new,
      form: Phoenix.Component.to_form(%{"id" => "", "password" => ""}, as: :login),
      title: title,
      page_title: title,
      id_label: label,
      id_type: type,
      action: action,
      role: role
    )
  end
end
