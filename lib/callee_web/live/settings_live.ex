defmodule CalleeWeb.SettingsLive do
  use CalleeWeb, :live_view
  import CalleeWeb.LiveHelpers
  alias Callee.{Accounts, Calls}

  @impl true
  def mount(_params, _session, socket) do
    role = socket.assigns.current_role
    u = socket.assigns.current_user

    {:ok,
     assign(socket,
       page_title: "Settings",
       pw_form: to_form(%{}, as: :pw),
       missed: Calls.missed_count(String.to_existing_atom(role), u.id)
     )}
  end

  @impl true
  def handle_event("change_pw", %{"pw" => p}, socket) do
    result =
      case socket.assigns.current_role do
        "tenant" ->
          Accounts.change_tenant_password(socket.assigns.current_user, p["current"], p["new"])

        "client" ->
          client_change(socket.assigns.current_user, p["current"], p["new"])
      end

    case result do
      {:ok, u} ->
        {:noreply,
         socket
         |> assign(current_user: u, pw_form: to_form(%{}, as: :pw))
         |> put_flash(:info, "Password updated.")}

      {:error, :wrong_password} ->
        {:noreply, put_flash(socket, :error, "Your current password is incorrect.")}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, errors_on(cs))}
    end
  end

  defp client_change(c, current, new) do
    if Bcrypt.verify_pass(current || "", c.password_hash),
      do: Accounts.change_client_password(c, %{password: new}),
      else: {:error, :wrong_password}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_role={@current_role}
      current_user={@current_user}
      active={:settings}
      missed={@missed}
    >
      <.page_header title="Settings" />

      <div class="card bg-base-100 shadow-sm">
        <div class="card-body flex-row items-center gap-4">
          <.avatar
            name={if @current_role == "tenant", do: @current_user.name, else: @current_user.mobile}
            size="w-14"
          />
          <div class="min-w-0">
            <%= if @current_role == "tenant" do %>
              <div class="font-semibold text-lg truncate">{@current_user.name}</div>
              <div class="text-sm text-base-content/60">@{@current_user.username}</div>
              <div class="text-sm text-base-content/60" title={fmt_dt(@current_user.expires_at)}>
                {expiry_label(@current_user.expires_at)}
              </div>
            <% else %>
              <div class="font-semibold text-lg">{@current_user.mobile}</div>
              <div class="text-sm text-base-content/60">Client account</div>
            <% end %>
          </div>
        </div>
      </div>

      <section class="card bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="font-semibold">Calling</h2>

          <div
            id="push-settings"
            phx-hook="PushSettings"
            phx-update="ignore"
            class="flex items-start gap-3"
          >
            <div class="rounded-full bg-primary/10 text-primary p-2.5">
              <.icon name="hero-bell-alert" class="size-5" />
            </div>
            <div class="flex-1 min-w-0">
              <div class="font-medium">Incoming call alerts</div>
              <div data-status class="text-sm text-base-content/60">Checking…</div>
            </div>
            <button data-action class="btn btn-sm btn-primary hidden">Turn on</button>
          </div>

          <div id="mic-test" phx-hook="MicTest" phx-update="ignore" class="flex items-start gap-3">
            <div class="rounded-full bg-success/10 text-success p-2.5">
              <.icon name="hero-microphone" class="size-5" />
            </div>
            <div class="flex-1 min-w-0">
              <div class="font-medium">Microphone</div>
              <div data-status class="text-sm text-base-content/60">
                Check your mic before a call.
              </div>
              <progress
                data-level
                class="progress progress-success w-full mt-2 hidden"
                value="0"
                max="100"
              >
              </progress>
            </div>
            <button data-action class="btn btn-sm">Test</button>
          </div>
        </div>
      </section>

      <section
        id="install-app"
        phx-hook="InstallApp"
        phx-update="ignore"
        class="card bg-base-100 shadow-sm hidden"
      >
        <div class="card-body flex-row items-start gap-3">
          <div class="rounded-full bg-secondary/10 text-secondary p-2.5">
            <.icon name="hero-device-phone-mobile" class="size-5" />
          </div>
          <div class="flex-1 min-w-0">
            <div class="font-medium">Install the app</div>
            <div data-status class="text-sm text-base-content/60">
              Open Callee from your home screen like a regular app.
            </div>
          </div>
          <button data-action class="btn btn-sm btn-secondary hidden">Install</button>
        </div>
      </section>

      <section class="card bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <h2 class="font-semibold">Appearance</h2>
          <div class="flex items-center justify-between">
            <span class="text-sm">Theme</span>
            <Layouts.theme_toggle />
          </div>
        </div>
      </section>

      <section class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="font-semibold">Change password</h2>
          <.form for={@pw_form} id="pw-form" phx-submit="change_pw">
            <.input
              field={@pw_form[:current]}
              type="password"
              label="Current password"
              required
              autocomplete="current-password"
            />
            <.input
              field={@pw_form[:new]}
              type="password"
              label="New password"
              required
              autocomplete="new-password"
            />
            <.button class="btn btn-primary" phx-disable-with="Saving…">Update password</.button>
          </.form>
        </div>
      </section>

      <.link href={~p"/logout"} method="delete" class="btn btn-outline btn-error w-full">
        <.icon name="hero-arrow-right-on-rectangle" class="size-5" /> Sign out
      </.link>
    </Layouts.app>
    """
  end
end
