defmodule CalleeWeb.TenantContactsLive do
  use CalleeWeb, :live_view
  import CalleeWeb.LiveHelpers
  alias Callee.{Accounts, Calls}
  alias CalleeWeb.ListParams

  @impl true
  def mount(_params, _session, socket) do
    t = socket.assigns.current_user
    if connected?(socket), do: Calls.subscribe_history({:tenant, t.id})

    {:ok,
     assign(socket,
       page_title: "Contacts",
       modal: nil,
       picking: false,
       picked: %{},
       group_max: Application.get_env(:callee, :group_max, 50) - 1,
       missed: Calls.missed_count(:tenant, t.id)
     )}
  end

  @impl true
  def handle_params(params, _url, socket),
    do: {:noreply, socket |> assign(params: ListParams.take(params)) |> load()}

  defp load(socket) do
    assign(socket,
      meta:
        Accounts.paginate_contacts_for_tenant(socket.assigns.current_user, socket.assigns.params)
    )
  end

  @impl true
  def handle_info({:call_updated, _}, socket),
    do:
      {:noreply,
       assign(socket, missed: Calls.missed_count(:tenant, socket.assigns.current_user.id))}

  defp suggest_password do
    # Easy to read out over the phone: no 0/O/1/l.
    alphabet = ~c"abcdefghjkmnpqrstuvwxyz23456789"
    for _ <- 1..8, into: "", do: <<Enum.random(alphabet)>>
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, ListParams.search(socket, ~p"/tenant", q)}

  # ---- group call picking (selection survives search + paging) ----
  def handle_event("group_mode", _, socket),
    do: {:noreply, assign(socket, picking: !socket.assigns.picking, picked: %{})}

  def handle_event("pick", %{"id" => id, "name" => name}, socket) do
    id = String.to_integer(id)
    picked = socket.assigns.picked

    cond do
      Map.has_key?(picked, id) ->
        {:noreply, assign(socket, picked: Map.delete(picked, id))}

      map_size(picked) >= socket.assigns.group_max ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "A group call can include up to #{socket.assigns.group_max} people."
         )}

      true ->
        {:noreply, assign(socket, picked: Map.put(picked, id, name))}
    end
  end

  def handle_event("save_group_prompt", _, socket),
    do: {:noreply, assign(socket, modal: :save_group, form: to_form(%{}, as: :group))}

  def handle_event("save_group", %{"group" => %{"name" => name}}, socket) do
    attrs = %{"name" => name, "client_ids" => Map.keys(socket.assigns.picked)}

    case Callee.Groups.save(socket.assigns.current_user.id, attrs) do
      {:ok, g} ->
        {:noreply,
         socket
         |> put_flash(:info, "Group “#{g.name}” saved. Call it any time from Groups.")
         |> push_navigate(to: ~p"/tenant/groups")}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, errors_on(cs))}
    end
  end

  def handle_event("new", _, socket),
    do:
      {:noreply,
       assign(socket,
         modal: :new,
         form: to_form(%{"password" => suggest_password()}, as: :contact)
       )}

  def handle_event("close", _, socket), do: {:noreply, assign(socket, modal: nil)}

  def handle_event("add", %{"contact" => p}, socket) do
    case Accounts.add_contact(socket.assigns.current_user, p) do
      {:ok, c, how} ->
        msg =
          if how == :created,
            do:
              "#{c.name} added. Share their sign-in: #{c.client.mobile} / the password you set.",
            else:
              "#{c.name} added. This number already has an account, so they keep their existing password."

        {:noreply, socket |> put_flash(:info, msg) |> assign(modal: nil) |> load()}

      {:error, cs} ->
        {:noreply,
         socket |> put_flash(:error, errors_on(cs)) |> assign(form: to_form(p, as: :contact))}
    end
  end

  def handle_event("rename", %{"id" => id}, socket) do
    c = Enum.find(socket.assigns.meta.entries, &(to_string(&1.id) == id))

    {:noreply,
     assign(socket, modal: {:rename, c}, form: to_form(%{"name" => c.name}, as: :rename))}
  end

  def handle_event("save_rename", %{"rename" => %{"name" => name}}, socket) do
    {:rename, c} = socket.assigns.modal

    case Accounts.update_contact_name(socket.assigns.current_user, c.id, name) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(modal: nil) |> put_flash(:info, "Renamed to #{name}.") |> load()}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, errors_on(cs))}
    end
  end

  def handle_event("reset", %{"id" => id}, socket) do
    c = Enum.find(socket.assigns.meta.entries, &(to_string(&1.id) == id))

    if Accounts.client_shared?(c.client_id) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "#{c.name}'s number is also used by another organisation, so only they can change the password (in Settings)."
       )}
    else
      {:noreply,
       assign(socket,
         modal: {:reset, c},
         form: to_form(%{"password" => suggest_password()}, as: :reset)
       )}
    end
  end

  def handle_event("save_reset", %{"reset" => %{"password" => pw}}, socket) do
    {:reset, c} = socket.assigns.modal

    case Accounts.reset_client_password(socket.assigns.current_user, c.id, pw) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(modal: nil)
         |> put_flash(:info, "New password for #{c.name}: #{pw}. Share it with them.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, errors_on(cs))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(modal: nil)
         |> put_flash(:error, "This password can't be reset from here.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Accounts.delete_contact(socket.assigns.current_user, id)

    {:noreply,
     socket |> put_flash(:info, "Contact removed. Past calls stay in your history.") |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_role="tenant"
      current_user={@current_user}
      active={:contacts}
      missed={@missed}
    >
      <.page_header
        title={if @picking, do: "New group call", else: "Contacts"}
        subtitle={
          if @picking,
            do: "Tap people to add them (2–#{@group_max})",
            else:
              "#{@meta.total} #{if @meta.total == 1, do: "client", else: "clients"} in your address book"
        }
      >
        <:actions>
          <button
            :if={!@picking && @meta.total >= 2}
            class="btn btn-ghost bg-base-100"
            phx-click="group_mode"
            aria-label="Group call"
          >
            <.icon name="hero-user-group" class="size-5" />
            <span class="hidden sm:inline">
              Group call
            </span>
          </button>
          <button :if={!@picking} class="btn btn-primary" phx-click="new">
            <.icon name="hero-user-plus" class="size-5" />
            <span>Add<span class="hidden sm:inline"> client</span></span>
          </button>
          <button :if={@picking} class="btn btn-ghost" phx-click="group_mode">Cancel</button>
        </:actions>
      </.page_header>

      <.search_bar value={@params["q"]} placeholder="Search name or mobile" />

      <div class="card bg-base-100 shadow-sm">
        <div class="card-body p-2 sm:p-4">
          <%= if @meta.entries == [] do %>
            <.empty_state
              :if={ListParams.filtered?(@params)}
              icon="hero-magnifying-glass"
              title="No matches"
              text={"Nobody matches “#{@params["q"]}”."}
            />
            <.empty_state
              :if={!ListParams.filtered?(@params)}
              icon="hero-user-group"
              title="Your address book is empty"
              text="Add a client with their mobile number. They sign in with that number and the password you set."
            >
              <button class="btn btn-primary btn-sm" phx-click="new">Add your first client</button>
            </.empty_state>
          <% else %>
            <ul class="divide-y divide-base-200">
              <li
                :for={c <- @meta.entries}
                id={"contact-#{c.id}"}
                class={[
                  "flex items-center gap-3 px-2 py-2.5 rounded-xl",
                  @picking && "cursor-pointer select-none active:bg-base-200",
                  Map.has_key?(@picked, c.client_id) && "bg-primary/10"
                ]}
                phx-click={@picking && "pick"}
                phx-value-id={c.client_id}
                phx-value-name={c.name}
              >
                <input
                  :if={@picking}
                  type="checkbox"
                  class="checkbox checkbox-primary checkbox-lg pointer-events-none"
                  checked={Map.has_key?(@picked, c.client_id)}
                  aria-label={"Select " <> c.name}
                  tabindex="-1"
                />
                <.avatar name={c.name} />
                <div class="flex-1 min-w-0">
                  <div class="font-medium truncate">{c.name}</div>
                  <div class="text-sm text-base-content/60">{c.client.mobile}</div>
                </div>
                <button
                  :if={!@picking}
                  class="btn btn-success btn-circle shadow-sm"
                  data-call-peer={c.client_id}
                  data-call-name={c.name}
                  aria-label={"Call " <> c.name}
                  title="Call"
                >
                  <.icon name="hero-phone-solid" class="size-5" />
                </button>
                <div :if={!@picking} class="dropdown dropdown-end">
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
                      <a phx-click="rename" phx-value-id={c.id}>
                        <.icon name="hero-pencil" class="size-4" /> Rename
                      </a>
                    </li>
                    <li>
                      <a phx-click="reset" phx-value-id={c.id}>
                        <.icon name="hero-key" class="size-4" /> Reset password
                      </a>
                    </li>
                    <li>
                      <a
                        class="text-error"
                        phx-click="delete"
                        phx-value-id={c.id}
                        data-confirm={"Remove #{c.name} from your address book? You won't be able to call each other."}
                      >
                        <.icon name="hero-trash" class="size-4" /> Remove
                      </a>
                    </li>
                  </ul>
                </div>
              </li>
            </ul>
          <% end %>
          <.pagination meta={@meta} path={~p"/tenant"} params={@params} noun="clients" />
        </div>
      </div>

      <div :if={@picking} class="h-24" aria-hidden="true"></div>
      <div :if={@picking} class="fixed inset-x-0 bottom-16 sm:bottom-4 z-30 px-3">
        <div class="mx-auto max-w-3xl card bg-base-100 shadow-xl border border-base-300">
          <div class="card-body p-3 flex-row items-center gap-3">
            <div class="flex-1 min-w-0">
              <div class="font-semibold">{map_size(@picked)} selected</div>
              <div class="text-sm text-base-content/60 truncate">
                {if @picked == %{},
                  do: "Pick at least 2 people",
                  else: @picked |> Map.values() |> Enum.sort() |> Enum.join(", ")}
              </div>
            </div>
            <button
              class="btn btn-ghost btn-lg rounded-full px-3"
              disabled={map_size(@picked) < 2}
              phx-click="save_group_prompt"
              title="Save as group"
              aria-label="Save as group"
            >
              <.icon name="hero-bookmark" class="size-5" /><span class="hidden sm:inline">Save</span>
            </button>
            <button
              class="btn btn-success btn-lg rounded-full"
              disabled={map_size(@picked) < 2}
              data-group-call={
                @picked |> Enum.sort_by(&elem(&1, 1)) |> Enum.map_join(",", &elem(&1, 0))
              }
              data-group-names={
                @picked |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 1)) |> Jason.encode!()
              }
              phx-click="group_mode"
            >
              <.icon name="hero-phone-solid" class="size-5" /> Call
            </button>
          </div>
        </div>
      </div>

      <dialog
        :if={@modal == :save_group}
        class="modal modal-bottom sm:modal-middle"
        open
        phx-window-keydown="close"
        phx-key="Escape"
      >
        <div class="modal-box">
          <h3 class="font-bold text-lg">Save as group</h3>
          <p class="text-sm text-base-content/60 mb-3">
            {@picked |> Map.values() |> Enum.sort() |> Enum.join(", ")}
          </p>
          <.form for={@form} id="save-group-form" phx-submit="save_group">
            <.input
              field={@form[:name]}
              label="Group name"
              placeholder="e.g. Morning team"
              required
              phx-mounted={JS.focus()}
            />
            <div class="modal-action">
              <button type="button" class="btn btn-ghost" phx-click="close">Cancel</button>
              <.button class="btn btn-primary">Save group</.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close"></div>
      </dialog>

      <dialog
        :if={@modal == :new}
        class="modal modal-bottom sm:modal-middle"
        open
        phx-window-keydown="close"
        phx-key="Escape"
      >
        <div class="modal-box">
          <h3 class="font-bold text-lg">Add client</h3>
          <p class="text-sm text-base-content/60 mb-3">
            They sign in with this mobile number. If the number already has an account, it's linked and its password stays the same.
          </p>
          <.form for={@form} id="contact-form" phx-submit="add">
            <.input
              field={@form[:name]}
              label="Name"
              placeholder="How they appear in your contacts"
              required
              phx-mounted={JS.focus()}
            />
            <.input
              field={@form[:mobile]}
              type="tel"
              inputmode="tel"
              autocomplete="tel"
              label="Mobile number"
              placeholder="+91 98765 43210"
              required
            />
            <.input
              field={@form[:password]}
              type="text"
              label="Password for new accounts"
              autocomplete="off"
            />
            <p class="text-xs text-base-content/60 -mt-1">
              We suggested an easy-to-share password. Change it if you like.
            </p>
            <div class="modal-action">
              <button type="button" class="btn btn-ghost" phx-click="close">Cancel</button>
              <.button class="btn btn-primary" phx-disable-with="Adding…">Add client</.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close"></div>
      </dialog>

      <dialog
        :if={match?({:reset, _}, @modal)}
        class="modal modal-bottom sm:modal-middle"
        open
        phx-window-keydown="close"
        phx-key="Escape"
      >
        <div class="modal-box">
          <h3 class="font-bold text-lg">Reset password</h3>
          <p class="text-sm text-base-content/60 mb-3">
            Set a new sign-in password for {elem(@modal, 1).name}.
          </p>
          <.form for={@form} id="reset-form" phx-submit="save_reset">
            <.input
              field={@form[:password]}
              type="text"
              label="New password"
              required
              autocomplete="off"
              phx-mounted={JS.focus()}
            />
            <div class="modal-action">
              <button type="button" class="btn btn-ghost" phx-click="close">Cancel</button>
              <.button class="btn btn-primary">Reset</.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close"></div>
      </dialog>

      <dialog
        :if={match?({:rename, _}, @modal)}
        class="modal modal-bottom sm:modal-middle"
        open
        phx-window-keydown="close"
        phx-key="Escape"
      >
        <div class="modal-box">
          <h3 class="font-bold text-lg mb-2">Rename contact</h3>
          <.form for={@form} id="rename-form" phx-submit="save_rename">
            <.input field={@form[:name]} label="Name" required phx-mounted={JS.focus()} />
            <div class="modal-action">
              <button type="button" class="btn btn-ghost" phx-click="close">Cancel</button>
              <.button class="btn btn-primary">Save</.button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="close"></div>
      </dialog>
    </Layouts.app>
    """
  end
end
