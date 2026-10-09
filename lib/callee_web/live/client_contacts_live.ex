defmodule CalleeWeb.ClientContactsLive do
  use CalleeWeb, :live_view
  alias Callee.{Accounts, Calls}
  alias Callee.Accounts.Tenant
  alias CalleeWeb.ListParams

  @impl true
  def mount(_params, _session, socket) do
    c = socket.assigns.current_user
    if connected?(socket), do: Calls.subscribe_history({:client, c.id})
    {:ok, assign(socket, page_title: "Contacts", missed: Calls.missed_count(:client, c.id))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    params = ListParams.take(params)

    {:noreply,
     assign(socket,
       params: params,
       meta: Accounts.paginate_tenants_for_client(socket.assigns.current_user, params)
     )}
  end

  @impl true
  def handle_info({:call_updated, _}, socket),
    do:
      {:noreply,
       assign(socket, missed: Calls.missed_count(:client, socket.assigns.current_user.id))}

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, ListParams.search(socket, ~p"/app", q)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_role="client"
      current_user={@current_user}
      active={:contacts}
      missed={@missed}
    >
      <.page_header title="Contacts" subtitle="Tap the green button to call." />
      <.search_bar
        :if={@meta.total > 5 or ListParams.filtered?(@params)}
        value={@params["q"]}
        placeholder="Search contacts"
      />

      <div class="card bg-base-100 shadow-sm">
        <div class="card-body p-2 sm:p-4">
          <%= if @meta.entries == [] do %>
            <.empty_state
              icon="hero-user-group"
              title={if ListParams.filtered?(@params), do: "No matches", else: "No contacts yet"}
              text={
                if ListParams.filtered?(@params),
                  do: "Try a different name.",
                  else: "When someone adds your number, they'll appear here."
              }
            />
          <% else %>
            <ul class="divide-y divide-base-200">
              <li
                :for={c <- @meta.entries}
                id={"tenant-#{c.tenant_id}"}
                class="flex items-center gap-3 px-2 py-3"
              >
                <.avatar name={c.tenant.name} size="w-12" />
                <div class="flex-1 min-w-0">
                  <div class="font-medium text-lg truncate">{c.tenant.name}</div>
                  <div :if={!Tenant.active?(c.tenant)} class="text-sm text-base-content/50">
                    Not available
                  </div>
                </div>
                <button
                  :if={Tenant.active?(c.tenant)}
                  class="btn btn-success btn-circle btn-lg shadow-sm"
                  data-call-peer={c.tenant_id}
                  data-call-name={c.tenant.name}
                  aria-label={"Call " <> c.tenant.name}
                >
                  <.icon name="hero-phone-solid" class="size-6" />
                </button>
              </li>
            </ul>
          <% end %>
          <.pagination meta={@meta} path={~p"/app"} params={@params} noun="contacts" />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
