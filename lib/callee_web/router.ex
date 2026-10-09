defmodule CalleeWeb.Router do
  use CalleeWeb, :router
  import CalleeWeb.Auth, only: [fetch_current: 2, redirect_if_signed_in: 2]

  pipeline :browser do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CalleeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"permissions-policy" => "microphone=(self)"}
    plug :fetch_current
  end

  pipeline :guest, do: plug(:redirect_if_signed_in)
  pipeline :admin, do: plug(:require_role, "admin")
  pipeline :tenant, do: plug(:require_role, "tenant")
  pipeline :client, do: plug(:require_role, "client")
  pipeline :caller, do: plug(:require_caller)

  defp require_role(conn, role), do: CalleeWeb.Auth.require_role(conn, role)

  defp require_caller(conn, _) do
    if conn.assigns[:current_role] in ["tenant", "client"],
      do: conn,
      else: conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
  end

  scope "/", CalleeWeb do
    pipe_through [:browser, :guest]
    get "/", SessionController, :home
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/tenant/login", SessionController, :new
    post "/tenant/login", SessionController, :create
    get "/admin/login", SessionController, :new
    post "/admin/login", SessionController, :create
  end

  scope "/", CalleeWeb do
    pipe_through :browser
    delete "/logout", SessionController, :delete
    get "/logout", SessionController, :delete
  end

  scope "/admin", CalleeWeb do
    pipe_through [:browser, :admin]

    live_session :admin, on_mount: {CalleeWeb.Auth, "admin"} do
      live "/", AdminLive, :index
    end
  end

  scope "/tenant", CalleeWeb do
    pipe_through [:browser, :tenant]
    post "/calls/:call_id/recording", RecordingController, :create
    get "/recordings/:id", RecordingController, :show

    live_session :tenant, on_mount: {CalleeWeb.Auth, "tenant"} do
      live "/", TenantContactsLive
      live "/groups", TenantGroupsLive
      live "/calls", TenantCallsLive
      live "/settings", SettingsLive
    end
  end

  scope "/app", CalleeWeb do
    pipe_through [:browser, :client]

    live_session :client, on_mount: {CalleeWeb.Auth, "client"} do
      live "/", ClientContactsLive
      live "/calls", ClientCallsLive
      live "/settings", SettingsLive
    end
  end

  scope "/push", CalleeWeb do
    pipe_through [:browser, :caller]
    post "/subscribe", PushController, :subscribe
    post "/unsubscribe", PushController, :unsubscribe
  end
end
