defmodule CalleeWeb.TenantCallsLive do
  use CalleeWeb, :live_view
  alias Callee.Calls
  alias CalleeWeb.ListParams

  @filters [
    {"all", "All"},
    {"missed", "Missed"},
    {"incoming", "Incoming"},
    {"outgoing", "Outgoing"},
    {"recorded", "Recorded"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    t = socket.assigns.current_user
    if connected?(socket), do: Calls.subscribe_history({:tenant, t.id})
    {:ok, assign(socket, page_title: "Calls", filters: @filters)}
  end

  @impl true
  def handle_params(params, _url, socket),
    do: {:noreply, socket |> assign(params: ListParams.take(params)) |> load()}

  defp load(socket) do
    t = socket.assigns.current_user
    meta = Calls.paginate_calls_for_tenant(t.id, socket.assigns.params)

    # contact names for group participants on this page
    group_ids =
      for {%{kind: "group"} = call, _} <- meta.entries,
          p <- call.participants,
          uniq: true,
          do: p.client_id

    names =
      Map.new(Callee.Accounts.contacts_by_client_ids(t.id, group_ids), &{&1.client_id, &1.name})

    rows =
      Enum.map(meta.entries, fn
        {%{kind: "group"} = call, _} ->
          ps = Enum.sort_by(call.participants, &(names[&1.client_id] || ""))
          pnames = Enum.map(ps, &(names[&1.client_id] || &1.client.mobile))
          joined = Enum.count(ps, &(&1.joined_at != nil))
          callable = Enum.filter(ps, &Map.has_key?(names, &1.client_id))

          %{
            call: call,
            name: if(call.group, do: call.group.name, else: "Group · " <> summarize(pnames)),
            subtitle: call.group && summarize(pnames),
            status_text:
              if(call.status == "completed", do: "#{joined} of #{length(ps)} joined", else: nil),
            peer_id: nil,
            can_call: false,
            group_ids: if(length(callable) >= 2, do: Enum.map(callable, & &1.client_id)),
            saved_group: call.group && call.group.id,
            group_names: Enum.map(callable, &names[&1.client_id]),
            recording: call.recording
          }

        {call, name} ->
          %{
            call: call,
            name: name || (call.client && call.client.mobile) || "Unknown",
            subtitle: call.client && call.client.mobile,
            peer_id: call.client_id,
            can_call: not is_nil(name),
            recording: call.recording
          }
      end)

    assign(socket, meta: meta, rows: rows, missed: Calls.missed_count(:tenant, t.id))
  end

  @impl true
  def handle_info({:call_updated, _}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, ListParams.search(socket, ~p"/tenant/calls", q)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_role="tenant"
      current_user={@current_user}
      active={:calls}
      missed={@missed}
    >
      <.page_header
        title="Calls"
        subtitle="History and recordings. Only you can hear your recordings."
      />
      <.search_bar value={@params["q"]} placeholder="Search by contact or mobile" />
      <.filter_chips
        options={@filters}
        selected={@params["filter"] || "all"}
        path={~p"/tenant/calls"}
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
                  else: "Calls you make or receive will show up here, with recordings."
              }
            />
          <% else %>
            <.call_list rows={@rows} me="tenant" show_recordings />
          <% end %>
          <.pagination meta={@meta} path={~p"/tenant/calls"} params={@params} noun="calls" />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp summarize([a, b, _c | rest]), do: "#{a}, #{b} +#{length(rest) + 1}"
  defp summarize(list), do: Enum.join(list, ", ")
end
