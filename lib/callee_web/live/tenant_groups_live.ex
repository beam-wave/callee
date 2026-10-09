defmodule CalleeWeb.TenantGroupsLive do
  @moduledoc "Saved groups: create once, call with one tap."
  use CalleeWeb, :live_view
  import CalleeWeb.LiveHelpers
  alias Callee.{Accounts, Calls, Groups}
  alias CalleeWeb.ListParams

  @impl true
  def mount(_params, _session, socket) do
    t = socket.assigns.current_user
    if connected?(socket), do: Calls.subscribe_history({:tenant, t.id})

    {:ok,
     assign(socket,
       page_title: "Groups",
       modal: nil,
       max: Groups.max_members(),
       missed: Calls.missed_count(:tenant, t.id)
     )}
  end

  @impl true
  def handle_params(params, _url, socket),
    do: {:noreply, socket |> assign(params: ListParams.take(params)) |> load()}

  defp load(socket) do
    t = socket.assigns.current_user
    meta = Groups.paginate(t.id, socket.assigns.params)
    # names as the tenant knows them (contact names), only current contacts
    rows = Enum.map(meta.entries, fn g -> {g, Groups.members_with_names(g)} end)
    assign(socket, meta: meta, rows: rows)
  end

  @impl true
  def handle_info({:call_updated, _}, socket),
    do:
      {:noreply,
       assign(socket, missed: Calls.missed_count(:tenant, socket.assigns.current_user.id))}

  ## Editor (name + searchable member picker inside a sheet)

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, ListParams.search(socket, ~p"/tenant/groups", q)}

  def handle_event("new", _, socket), do: {:noreply, open_editor(socket, nil, "", %{})}

  def handle_event("edit", %{"id" => id}, socket) do
    g = Groups.get(socket.assigns.current_user.id, id)
    {:noreply, open_editor(socket, g, g.name, Map.new(Groups.members_with_names(g)))}
  end

  def handle_event("close", _, socket), do: {:noreply, assign(socket, modal: nil)}

  def handle_event("member_search", %{"mq" => q}, socket) do
    {:noreply, socket |> update(:modal, &%{&1 | mq: q}) |> load_candidates()}
  end

  def handle_event("toggle_member", %{"id" => id, "name" => name}, socket) do
    id = String.to_integer(id)
    m = socket.assigns.modal

    picked =
      cond do
        Map.has_key?(m.picked, id) -> Map.delete(m.picked, id)
        map_size(m.picked) >= socket.assigns.max -> m.picked
        true -> Map.put(m.picked, id, name)
      end

    {:noreply, assign(socket, modal: %{m | picked: picked})}
  end

  def handle_event("save", %{"group" => %{"name" => name}}, socket) do
    m = socket.assigns.modal
    attrs = %{"name" => name, "client_ids" => Map.keys(m.picked)}

    case Groups.save(socket.assigns.current_user.id, attrs, m.group) do
      {:ok, g} ->
        {:noreply,
         socket |> assign(modal: nil) |> put_flash(:info, "Group “#{g.name}” saved.") |> load()}

      {:error, cs} ->
        {:noreply, socket |> assign(modal: %{m | name: name}) |> put_flash(:error, errors_on(cs))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Groups.delete(socket.assigns.current_user.id, id)

    {:noreply,
     socket |> put_flash(:info, "Group deleted. Past calls stay in your history.") |> load()}
  end

  defp open_editor(socket, group, name, picked) do
    socket
    |> assign(modal: %{group: group, name: name, picked: picked, mq: "", candidates: []})
    |> load_candidates()
  end

  defp load_candidates(socket) do
    m = socket.assigns.modal
    meta = Accounts.paginate_contacts_for_tenant(socket.assigns.current_user, %{"q" => m.mq})
    assign(socket, modal: %{m | candidates: meta.entries})
  end

  defp summarize(names) do
    case names do
      [a, b, _c | rest] -> "#{a}, #{b} +#{length(rest) + 1}"
      list -> Enum.join(list, ", ")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_role="tenant"
      current_user={@current_user}
      active={:groups}
      missed={@missed}
    >
      <.page_header
        title="Groups"
        subtitle="Save people you call together, then call them with one tap."
      >
        <:actions>
          <button class="btn btn-primary" phx-click="new">
            <.icon name="hero-plus" class="size-5" /><span>
              New<span class="hidden sm:inline"> group</span>
            </span>
          </button>
        </:actions>
      </.page_header>

      <.search_bar
        :if={@meta.total > 5 or ListParams.filtered?(@params)}
        value={@params["q"]}
        placeholder="Search groups"
      />

      <div class="card bg-base-100 shadow-sm">
        <div class="card-body p-2 sm:p-4">
          <%= if @rows == [] do %>
            <.empty_state
              icon="hero-user-group"
              title={
                if ListParams.filtered?(@params), do: "No matching groups", else: "No groups yet"
              }
              text={
                if ListParams.filtered?(@params),
                  do: "Try another name.",
                  else: "Create a group once, e.g. “Morning team”, and call everyone in it together."
              }
            >
              <button
                :if={!ListParams.filtered?(@params)}
                class="btn btn-primary btn-sm"
                phx-click="new"
              >
                Create a group
              </button>
            </.empty_state>
          <% else %>
            <ul class="divide-y divide-base-200">
              <li
                :for={{g, members} <- @rows}
                id={"group-#{g.id}"}
                class="flex items-center gap-3 px-2 py-3"
              >
                <div class="rounded-full bg-secondary/15 text-secondary size-11 flex items-center justify-center shrink-0">
                  <.icon name="hero-user-group" class="size-6" />
                </div>
                <div class="flex-1 min-w-0">
                  <div class="font-medium truncate">{g.name}</div>
                  <div class="text-sm text-base-content/60 truncate">
                    {length(members)} people · {summarize(Enum.map(members, &elem(&1, 1)))}
                  </div>
                </div>
                <button
                  :if={length(members) >= 2}
                  class="btn btn-success btn-circle shadow-sm"
                  data-saved-group={g.id}
                  data-group-name={g.name}
                  data-group-call={Enum.map_join(members, ",", &elem(&1, 0))}
                  data-group-names={Jason.encode!(Enum.map(members, &elem(&1, 1)))}
                  aria-label={"Call " <> g.name}
                  title="Call group"
                >
                  <.icon name="hero-phone-solid" class="size-5" />
                </button>
                <div class="dropdown dropdown-end">
                  <div
                    tabindex="0"
                    role="button"
                    class="btn btn-ghost btn-circle"
                    aria-label="More actions"
                  >
                    <.icon name="hero-ellipsis-vertical" class="size-5" />
                  </div>
                  <ul
                    tabindex="0"
                    class="dropdown-content menu menu-lg sm:menu-md bg-base-100 rounded-box z-10 w-52 p-2 shadow-lg border border-base-200"
                  >
                    <li>
                      <a phx-click="edit" phx-value-id={g.id}>
                        <.icon name="hero-pencil" class="size-4" /> Edit
                      </a>
                    </li>
                    <li>
                      <a
                        class="text-error"
                        phx-click="delete"
                        phx-value-id={g.id}
                        data-confirm={"Delete the group “#{g.name}”?"}
                      >
                        <.icon name="hero-trash" class="size-4" /> Delete
                      </a>
                    </li>
                  </ul>
                </div>
              </li>
            </ul>
          <% end %>
          <.pagination meta={@meta} path={~p"/tenant/groups"} params={@params} noun="groups" />
        </div>
      </div>

      <dialog
        :if={@modal}
        class="modal modal-bottom sm:modal-middle"
        open
        phx-window-keydown="close"
        phx-key="Escape"
      >
        <div class="modal-box max-h-[90dvh] flex flex-col">
          <h3 class="font-bold text-lg">{if @modal.group, do: "Edit group", else: "New group"}</h3>
          <.form
            for={%{}}
            as={:group}
            id="group-form"
            phx-submit="save"
            class="flex flex-col min-h-0 gap-3 mt-2"
          >
            <label class="floating-label">
              <span>Group name</span>
              <input
                name="group[name]"
                value={@modal.name}
                class="input w-full"
                placeholder="Group name, e.g. Morning team"
                required
                maxlength="60"
                phx-mounted={!@modal.group && JS.focus()}
              />
            </label>

            <div class="flex flex-wrap gap-1.5" aria-live="polite">
              <button
                :for={{id, name} <- Enum.sort_by(@modal.picked, &elem(&1, 1))}
                type="button"
                class="badge badge-primary gap-1 h-8 px-3"
                phx-click="toggle_member"
                phx-value-id={id}
                phx-value-name={name}
                aria-label={"Remove " <> name}
              >
                {name} <.icon name="hero-x-mark" class="size-3.5" />
              </button>
              <span :if={@modal.picked == %{}} class="text-sm text-base-content/60">
                Pick 2–{@max} people below.
              </span>
            </div>

            <label class="input w-full rounded-full">
              <.icon name="hero-magnifying-glass" class="size-5 opacity-50" />
              <input
                type="search"
                name="mq"
                value={@modal.mq}
                placeholder="Search contacts"
                phx-change="member_search"
                phx-debounce="250"
                autocomplete="off"
                class="grow"
              />
            </label>

            <ul class="overflow-y-auto min-h-0 flex-1 -mx-2 max-h-72">
              <li
                :for={c <- @modal.candidates}
                class={[
                  "flex items-center gap-3 px-2 py-2 rounded-xl cursor-pointer active:bg-base-200",
                  Map.has_key?(@modal.picked, c.client_id) && "bg-primary/10"
                ]}
                phx-click="toggle_member"
                phx-value-id={c.client_id}
                phx-value-name={c.name}
              >
                <input
                  type="checkbox"
                  class="checkbox checkbox-primary pointer-events-none"
                  checked={Map.has_key?(@modal.picked, c.client_id)}
                  tabindex="-1"
                />
                <.avatar name={c.name} size="w-9" />
                <span class="flex-1 truncate">{c.name}</span>
              </li>
              <li :if={@modal.candidates == []} class="text-sm text-center text-base-content/60 py-4">
                No contacts match.
              </li>
            </ul>

            <div class="modal-action mt-0">
              <button type="button" class="btn btn-ghost" phx-click="close">Cancel</button>
              <.button class="btn btn-primary" disabled={map_size(@modal.picked) < 2}>
                Save ({map_size(@modal.picked)})
              </.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close"></div>
      </dialog>
    </Layouts.app>
    """
  end
end
