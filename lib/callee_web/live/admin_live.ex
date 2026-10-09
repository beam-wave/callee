defmodule CalleeWeb.AdminLive do
  use CalleeWeb, :live_view
  import CalleeWeb.LiveHelpers
  alias Callee.Accounts
  alias Callee.Accounts.Tenant

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Tenants", editing: nil, creating: false, form_key: 0)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    params = Map.take(params, ["q", "filter", "page"])

    {:noreply,
     socket
     |> assign(params: params)
     |> load()}
  end

  defp load(socket) do
    p = socket.assigns.params

    assign(socket,
      meta:
        Accounts.paginate_tenants(%{"q" => p["q"], "status" => p["filter"], "page" => p["page"]}),
      counts: Accounts.tenant_counts()
    )
  end

  defp end_of_day(date_str) do
    case Date.from_iso8601(date_str || "") do
      {:ok, d} -> DateTime.new!(d, ~T[23:59:59], "Etc/UTC")
      _ -> nil
    end
  end

  defp new_form,
    do: to_form(%{"expires_on" => Date.to_iso8601(Date.add(Date.utc_today(), 30))}, as: :tenant)

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply,
     push_patch(socket,
       to: patch_url(~p"/admin", Map.merge(socket.assigns.params, %{"q" => q, "page" => nil}))
     )}
  end

  def handle_event("new", _, socket),
    do: {:noreply, assign(socket, creating: true, form: new_form())}

  def handle_event("close", _, socket),
    do: {:noreply, assign(socket, creating: false, editing: nil)}

  def handle_event("create", %{"tenant" => p}, socket) do
    attrs = Map.put(p, "expires_at", end_of_day(p["expires_on"]))

    case Accounts.create_tenant(attrs) do
      {:ok, t} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tenant “#{t.name}” created. They can sign in as #{t.username}.")
         |> assign(creating: false)
         |> load()}

      {:error, cs} ->
        {:noreply,
         socket
         |> put_flash(:error, errors_on(cs))
         |> assign(form: to_form(Map.delete(p, "password"), as: :tenant))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    t = Accounts.get_tenant!(id)

    {:noreply,
     assign(socket,
       editing: t,
       edit_form:
         to_form(
           %{
             "name" => t.name,
             "expires_on" => Date.to_iso8601(DateTime.to_date(t.expires_at)),
             "password" => "",
             "disabled" => t.disabled
           },
           as: :edit
         )
     )}
  end

  def handle_event("save_edit", %{"edit" => p}, socket) do
    attrs =
      %{
        "name" => p["name"],
        "expires_at" => end_of_day(p["expires_on"]),
        "disabled" => p["disabled"] == "true"
      }
      |> then(fn a ->
        if p["password"] in [nil, ""], do: a, else: Map.put(a, "password", p["password"])
      end)

    case Accounts.update_tenant(socket.assigns.editing, attrs) do
      {:ok, t} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved changes to “#{t.name}”.")
         |> assign(editing: nil)
         |> load()}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, errors_on(cs))}
    end
  end

  def handle_event("extend", %{"id" => id, "days" => days}, socket) do
    t = Accounts.get_tenant!(id)
    base = Enum.max([t.expires_at, DateTime.utc_now()], DateTime)
    new = DateTime.add(base, String.to_integer(days) * 86_400) |> DateTime.truncate(:second)
    {:ok, t} = Accounts.update_tenant(t, %{expires_at: new})
    {:noreply, socket |> put_flash(:info, "“#{t.name}” now expires #{fmt_date(new)}.") |> load()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    t = Accounts.get_tenant!(id)
    {:ok, t} = Accounts.update_tenant(t, %{disabled: !t.disabled})
    msg = if t.disabled, do: "“#{t.name}” disabled.", else: "“#{t.name}” enabled."
    {:noreply, socket |> put_flash(:info, msg) |> load()}
  end

  defp state(t) do
    cond do
      t.disabled -> {"badge-ghost", "Disabled"}
      Tenant.active?(t) -> {"badge-success", "Active"}
      true -> {"badge-error", "Expired"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_role="admin" wide>
      <.page_header title="Tenants" subtitle="Create tenant accounts and control when they expire.">
        <:actions>
          <button class="btn btn-primary" phx-click="new">
            <.icon name="hero-plus" class="size-5" /> New tenant
          </button>
        </:actions>
      </.page_header>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <.link
          :for={
            {key, label, cls} <- [
              {"all", "Total", ""},
              {"active", "Active", "text-success"},
              {"expired", "Expired", "text-error"},
              {"disabled", "Disabled", "opacity-60"}
            ]
          }
          patch={patch_url(~p"/admin", %{"filter" => key, "q" => @params["q"]})}
          class={[
            "card bg-base-100 shadow-sm hover:shadow transition border-2",
            if((@params["filter"] || "all") == key, do: "border-primary", else: "border-transparent")
          ]}
        >
          <div class="card-body p-4">
            <div class="text-xs uppercase tracking-wide text-base-content/60">{label}</div>
            <div class={["text-2xl font-bold", cls]}>
              {Map.get(@counts, String.to_existing_atom(key))}
            </div>
          </div>
        </.link>
      </div>

      <div class="card bg-base-100 shadow-sm">
        <div class="card-body p-3 sm:p-5 gap-3">
          <.search_bar value={@params["q"]} placeholder="Search by name or username" />

          <%= if @meta.entries == [] do %>
            <.empty_state
              icon="hero-building-office-2"
              title={
                if @params["q"] || @params["filter"],
                  do: "No matching tenants",
                  else: "No tenants yet"
              }
              text={
                if @params["q"] || @params["filter"],
                  do: "Try a different search or filter.",
                  else: "Create the first tenant to get started."
              }
            >
              <button
                :if={!(@params["q"] || @params["filter"])}
                class="btn btn-primary btn-sm"
                phx-click="new"
              >
                New tenant
              </button>
            </.empty_state>
          <% else %>
            <ul class="divide-y divide-base-200">
              <li
                :for={t <- @meta.entries}
                id={"tenant-#{t.id}"}
                class="flex flex-wrap sm:flex-nowrap items-center gap-3 py-3"
              >
                <.avatar name={t.name} />
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2">
                    <span class="font-semibold truncate">{t.name}</span>
                    <% {cls, label} = state(t) %>
                    <span class={["badge badge-sm", cls]}>{label}</span>
                  </div>
                  <div class="text-sm text-base-content/60 truncate">
                    @{t.username} ·
                    <span title={fmt_dt(t.expires_at)}>{expiry_label(t.expires_at)}</span>
                  </div>
                </div>
                <div class="flex gap-1 w-full sm:w-auto justify-end">
                  <button
                    class="btn btn-sm btn-ghost"
                    phx-click="extend"
                    phx-value-id={t.id}
                    phx-value-days="30"
                    title="Extend 30 days"
                  >
                    +30 days
                  </button>
                  <button
                    class="btn btn-sm btn-ghost"
                    phx-click="toggle"
                    phx-value-id={t.id}
                    data-confirm={
                      !t.disabled &&
                        "Disable “#{t.name}”? They will be signed out of calling immediately."
                    }
                  >
                    {if t.disabled, do: "Enable", else: "Disable"}
                  </button>
                  <button class="btn btn-sm" phx-click="edit" phx-value-id={t.id}>
                    <.icon name="hero-pencil-square" class="size-4" /> Edit
                  </button>
                </div>
              </li>
            </ul>
          <% end %>

          <.pagination meta={@meta} path={~p"/admin"} params={@params} noun="tenants" />
        </div>
      </div>

      <dialog
        :if={@creating}
        id="create-modal"
        class="modal modal-bottom sm:modal-middle"
        open
        phx-window-keydown="close"
        phx-key="Escape"
      >
        <div class="modal-box">
          <h3 class="font-bold text-lg">New tenant</h3>
          <p class="text-sm text-base-content/60 mb-3">
            The tenant signs in at /tenant/login with this username and password.
          </p>
          <.form for={@form} id="tenant-form" phx-submit="create">
            <.input
              field={@form[:name]}
              label="Display name"
              placeholder="e.g. Acme Clinic"
              required
              phx-mounted={JS.focus()}
            />
            <.input
              field={@form[:username]}
              label="Username"
              placeholder="acme"
              required
              autocomplete="off"
              autocapitalize="none"
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              placeholder="At least 8 characters"
              required
              autocomplete="new-password"
            />
            <.input
              field={@form[:expires_on]}
              type="date"
              label="Access until (end of day, UTC)"
              required
            />
            <div class="modal-action">
              <button type="button" class="btn btn-ghost" phx-click="close">Cancel</button>
              <.button class="btn btn-primary" phx-disable-with="Creating…">Create tenant</.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close"></div>
      </dialog>

      <dialog
        :if={@editing}
        id="edit-modal"
        class="modal modal-bottom sm:modal-middle"
        open
        phx-window-keydown="close"
        phx-key="Escape"
      >
        <div class="modal-box">
          <h3 class="font-bold text-lg">Edit {@editing.name}</h3>
          <p class="text-sm text-base-content/60 mb-3">@{@editing.username}</p>
          <.form for={@edit_form} id="edit-form" phx-submit="save_edit">
            <.input field={@edit_form[:name]} label="Display name" required />
            <.input field={@edit_form[:expires_on]} type="date" label="Access until" required />
            <.input
              field={@edit_form[:password]}
              type="password"
              label="New password"
              placeholder="Leave blank to keep current"
              autocomplete="new-password"
            />
            <.input field={@edit_form[:disabled]} type="checkbox" label="Disable this tenant" />
            <div class="modal-action">
              <button type="button" class="btn btn-ghost" phx-click="close">Cancel</button>
              <.button class="btn btn-primary" phx-disable-with="Saving…">Save</.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close"></div>
      </dialog>
    </Layouts.app>
    """
  end
end
