defmodule CalleeWeb.ClientCallsLive do
  use CalleeWeb, :live_view
  alias Callee.{Accounts, Calls}
  alias CalleeWeb.ListParams

  @filters [
    {"all", "All"},
    {"missed", "Missed"},
    {"incoming", "Incoming"},
    {"outgoing", "Outgoing"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    c = socket.assigns.current_user
    if connected?(socket), do: Calls.subscribe_history({:client, c.id})
    {:ok, assign(socket, page_title: "Calls", filters: @filters)}
  end

  @impl true
  def handle_params(params, _url, socket),
    do: {:noreply, socket |> assign(params: ListParams.take(params)) |> load()}

  defp load(socket) do
    c = socket.assigns.current_user
    meta = Calls.paginate_calls_for_client(c.id, socket.assigns.params)

    callable =
      Accounts.list_tenants_for_client(c)
      |> Enum.filter(&Callee.Accounts.Tenant.active?(&1.tenant))
      |> MapSet.new(& &1.tenant_id)

    outcome = %{
      "joined" => {"Joined", false},
      "left" => {"Joined", false},
      "declined" => {"Declined", true},
      "missed" => {"Missed", true},
      "busy" => {"Busy", true},
      "ringing" => {"Ringing", false}
    }

    rows =
      Enum.map(meta.entries, fn call ->
        base = %{
          call: call,
          name: call.tenant.name,
          subtitle: nil,
          peer_id: call.tenant_id,
          can_call: MapSet.member?(callable, call.tenant_id),
          recording: nil
        }

        case {call.kind, call.participants} do
          {"group", [me | _]} ->
            {text, missed?} = Map.get(outcome, me.status, {me.status, false})

            Map.merge(base, %{
              name: call.tenant.name <> " · group",
              status_text: "Group call · " <> text,
              missed: missed?
            })

          _ ->
            base
        end
      end)

    assign(socket, meta: meta, rows: rows, missed: Calls.missed_count(:client, c.id))
  end

  @impl true
  def handle_info({:call_updated, _}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, ListParams.search(socket, ~p"/app/calls", q)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_role="client"
      current_user={@current_user}
      active={:calls}
      missed={@missed}
    >
      <.page_header title="Calls" />
      <.filter_chips
        options={@filters}
        selected={@params["filter"] || "all"}
        path={~p"/app/calls"}
        params={@params}
      />
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body p-3 sm:p-5">
          <%= if @rows == [] do %>
            <.empty_state
              icon="hero-phone"
              title={if ListParams.filtered?(@params), do: "No calls match", else: "No calls yet"}
              text={
                if ListParams.filtered?(@params),
                  do: "Try another filter.",
                  else: "Your calls will show up here."
              }
            />
          <% else %>
            <.call_list rows={@rows} me="client" />
          <% end %>
          <.pagination meta={@meta} path={~p"/app/calls"} params={@params} noun="calls" />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
