defmodule CalleeWeb.UI do
  @moduledoc "App-specific UI building blocks."
  use Phoenix.Component
  use CalleeWeb, :verified_routes
  import CalleeWeb.CoreComponents, only: [icon: 1]

  @doc "Builds a patch URL, dropping blank params and page=1."
  def patch_url(path, params) do
    query =
      params
      |> Enum.reject(fn {k, v} ->
        v in [nil, "", "all"] or (to_string(k) == "page" and to_string(v) == "1")
      end)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    if query == %{}, do: path, else: path <> "?" <> URI.encode_query(query)
  end

  ## Page header

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="flex items-end justify-between gap-3">
      <div class="min-w-0">
        <h1 class="text-2xl font-bold tracking-tight">{@title}</h1>
        <p :if={@subtitle} class="text-sm text-base-content/60 mt-0.5">{@subtitle}</p>
      </div>
      <div class="flex gap-2 shrink-0">{render_slot(@actions)}</div>
    </div>
    """
  end

  ## Search

  attr :value, :string, default: ""
  attr :placeholder, :string, default: "Search"
  attr :id, :string, default: "search"

  def search_bar(assigns) do
    ~H"""
    <form id={@id} phx-change="search" phx-submit="search" class="w-full" role="search">
      <label class="input input-bordered w-full flex items-center gap-2 rounded-full">
        <.icon name="hero-magnifying-glass" class="size-5 opacity-50" />
        <input
          type="search"
          name="q"
          value={@value}
          placeholder={@placeholder}
          phx-debounce="300"
          autocomplete="off"
          class="grow"
          aria-label={@placeholder}
        />
      </label>
    </form>
    """
  end

  ## Filter chips

  attr :options, :list, required: true, doc: "[{value, label}] or [{value, label, count}]"
  attr :selected, :string, default: "all"
  attr :path, :string, required: true
  attr :params, :map, default: %{}

  def filter_chips(assigns) do
    ~H"""
    <div class="flex gap-2 overflow-x-auto no-scrollbar -mx-1 px-1 py-0.5" role="tablist">
      <.link
        :for={opt <- @options}
        patch={patch_url(@path, Map.merge(@params, %{"filter" => elem(opt, 0), "page" => nil}))}
        role="tab"
        aria-selected={to_string(@selected == elem(opt, 0))}
        class={[
          "btn btn-sm rounded-full whitespace-nowrap",
          if(@selected == elem(opt, 0), do: "btn-primary", else: "btn-ghost bg-base-200")
        ]}
      >
        {elem(opt, 1)}
        <span :if={tuple_size(opt) == 3} class="badge badge-sm">{elem(opt, 2)}</span>
      </.link>
    </div>
    """
  end

  ## Pagination

  attr :meta, :map, required: true, doc: "%Callee.Pagination{}"
  attr :path, :string, required: true
  attr :params, :map, default: %{}
  attr :noun, :string, default: "items"

  def pagination(assigns) do
    m = assigns.meta
    first = if m.total == 0, do: 0, else: (m.page - 1) * m.per_page + 1
    last = min(m.page * m.per_page, m.total)
    assigns = assign(assigns, first: first, last: last, pages: page_window(m.page, m.total_pages))

    ~H"""
    <nav
      :if={@meta.total > 0}
      class="flex flex-col sm:flex-row items-center justify-between gap-3 pt-2"
      aria-label="Pagination"
    >
      <p class="text-sm text-base-content/60">
        Showing <b>{@first}</b>–<b>{@last}</b> of
        <b>{@meta.total}</b> {if @meta.total == 1, do: String.trim_trailing(@noun, "s"), else: @noun}
      </p>
      <%!-- Phones: big prev/next with "Page x of y". Larger screens: numbered pages. --%>
      <div
        :if={@meta.total_pages > 1}
        class="flex sm:hidden items-center justify-between w-full gap-2"
      >
        <.link
          patch={patch_url(@path, Map.put(@params, "page", @meta.page - 1))}
          class={["btn flex-1", @meta.page == 1 && "btn-disabled"]}
        >
          <.icon name="hero-chevron-left" class="size-5" /> Prev
        </.link>
        <span class="text-sm text-base-content/70 whitespace-nowrap px-2">
          Page {@meta.page} of {@meta.total_pages}
        </span>
        <.link
          patch={patch_url(@path, Map.put(@params, "page", @meta.page + 1))}
          class={["btn flex-1", @meta.page == @meta.total_pages && "btn-disabled"]}
        >
          Next <.icon name="hero-chevron-right" class="size-5" />
        </.link>
      </div>
      <div :if={@meta.total_pages > 1} class="join hidden sm:inline-flex">
        <.link
          patch={patch_url(@path, Map.put(@params, "page", @meta.page - 1))}
          class={["join-item btn btn-sm", @meta.page == 1 && "btn-disabled"]}
          aria-label="Previous page"
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </.link>
        <%= for p <- @pages do %>
          <span :if={p == :gap} class="join-item btn btn-sm btn-disabled">…</span>
          <.link
            :if={p != :gap}
            patch={patch_url(@path, Map.put(@params, "page", p))}
            class={["join-item btn btn-sm", p == @meta.page && "btn-primary"]}
            aria-current={p == @meta.page && "page"}
          >
            {p}
          </.link>
        <% end %>
        <.link
          patch={patch_url(@path, Map.put(@params, "page", @meta.page + 1))}
          class={["join-item btn btn-sm", @meta.page == @meta.total_pages && "btn-disabled"]}
          aria-label="Next page"
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </.link>
      </div>
    </nav>
    """
  end

  defp page_window(_page, total) when total <= 7, do: Enum.to_list(1..total)

  defp page_window(page, total) do
    mids = Enum.filter((page - 1)..(page + 1), &(&1 > 1 and &1 < total))

    [1] ++
      if(hd(mids) > 2, do: [:gap], else: []) ++
      mids ++
      if(List.last(mids) < total - 1, do: [:gap], else: []) ++ [total]
  end

  ## Avatar

  @colors ~w[ bg-indigo-500 bg-violet-500 bg-sky-600 bg-emerald-600 bg-amber-600 bg-rose-500 bg-teal-600 bg-fuchsia-600 ]

  attr :name, :string, required: true
  attr :size, :string, default: "w-11"

  def avatar(assigns) do
    i = :erlang.phash2(assigns.name || "", length(@colors))

    initials =
      (assigns.name || "?")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.take(2)
      |> Enum.map_join(&String.first/1)
      |> String.upcase()

    assigns = assign(assigns, bg: Enum.at(@colors, i), fg: "text-white", initials: initials)

    ~H"""
    <div class="avatar avatar-placeholder shrink-0" aria-hidden="true">
      <div class={[@bg, @fg, @size, "rounded-full"]}>
        <span class="font-semibold">{@initials}</span>
      </div>
    </div>
    """
  end

  ## Empty state

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :text, :string, default: nil
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center text-center py-14 px-6 gap-3">
      <div class="rounded-full bg-base-200 p-5">
        <.icon name={@icon} class="size-10 text-base-content/40" />
      </div>
      <h3 class="font-semibold text-lg">{@title}</h3>
      <p :if={@text} class="text-sm text-base-content/60 max-w-xs">{@text}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  ## Call row icon

  attr :call, :map, required: true
  attr :me, :string, required: true
  attr :missed, :boolean, default: nil

  def call_icon(assigns) do
    c = assigns.call
    outgoing = c.caller_type == assigns.me

    missed =
      if is_nil(assigns.missed),
        do: !outgoing and c.status in ["missed", "rejected", "busy"],
        else: assigns.missed

    {name, cls} =
      cond do
        missed -> {"hero-phone-x-mark", "text-error bg-error/10"}
        c.kind == "group" -> {"hero-user-group", "text-secondary bg-secondary/10"}
        outgoing -> {"hero-phone-arrow-up-right", "text-info bg-info/10"}
        true -> {"hero-phone-arrow-down-left", "text-success bg-success/10"}
      end

    assigns =
      assign(assigns, name: name, cls: cls, label: if(outgoing, do: "Outgoing", else: "Incoming"))

    ~H"""
    <div class={["rounded-full p-2.5 shrink-0", @cls]} title={@label}>
      <.icon name={@name} class="size-5" />
    </div>
    """
  end

  ## Call history list

  @doc """
  Day-grouped call history. `rows` are maps:
  %{call: %Call{}, name: str, subtitle: str | nil, peer_id: id, can_call: bool, recording: rec | nil}
  """
  attr :rows, :list, required: true
  attr :me, :string, required: true
  attr :show_recordings, :boolean, default: false

  def call_list(assigns) do
    assigns =
      assign(assigns,
        groups: CalleeWeb.LiveHelpers.group_by_day(assigns.rows, & &1.call.inserted_at)
      )

    ~H"""
    <div :for={{label, rows} <- @groups} class="space-y-1">
      <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50 px-1 pt-2">
        {label}
      </h3>
      <ul class="divide-y divide-base-200">
        <li :for={r <- rows} id={"call-#{r.call.id}"} class="py-3 space-y-2">
          <div class="flex items-center gap-3">
            <.call_icon call={r.call} me={@me} missed={r[:missed]} />
            <div class="flex-1 min-w-0">
              <div class={[
                "font-medium truncate",
                if(is_nil(r[:missed]),
                  do: r.call.status == "missed" and r.call.caller_type != @me,
                  else: r[:missed]
                ) && "text-error"
              ]}>
                {r.name}
              </div>
              <div class="text-xs text-base-content/60 flex flex-wrap gap-x-2">
                <span>{CalleeWeb.LiveHelpers.fmt_time(r.call.inserted_at)}</span>
                <span>·</span>
                <span>{r[:status_text] || CalleeWeb.LiveHelpers.status_text(r.call.status)}</span>
                <span :if={d = CalleeWeb.LiveHelpers.fmt_duration(r.call.duration_seconds)}>
                  · {d}
                </span>
                <span :if={r.subtitle} class="hidden sm:inline">· {r.subtitle}</span>
              </div>
            </div>
            <span
              :if={@show_recordings && match?(%{status: "ready"}, r.recording)}
              class="badge badge-sm badge-ghost gap-1"
              title="Recorded"
            >
              <.icon name="hero-microphone" class="size-3" /> Rec
            </span>
            <button
              :if={r[:group_ids] && r.call.status not in ["ringing", "active"]}
              class="btn btn-circle btn-ghost text-success"
              data-group-call={Enum.join(r.group_ids, ",")}
              data-saved-group={r[:saved_group]}
              data-group-name={r[:saved_group] && r.name}
              data-group-names={Jason.encode!(r.group_names)}
              aria-label="Call this group again"
              title="Call group again"
            >
              <.icon name="hero-user-group" class="size-5" />
            </button>
            <button
              :if={r.can_call and r.call.status not in ["ringing", "active"]}
              class="btn btn-circle btn-ghost text-success"
              data-call-peer={r.peer_id}
              data-call-name={r.name}
              aria-label={"Call " <> r.name}
              title="Call back"
            >
              <.icon name="hero-phone" class="size-5" />
            </button>
          </div>
          <%= if @show_recordings do %>
            <%= case r.recording do %>
              <% %{status: "ready"} = rec -> %>
                <div class="flex items-center gap-2 pl-12">
                  <audio
                    controls
                    preload="none"
                    class="w-full h-10"
                    src={~p"/tenant/recordings/#{rec.id}"}
                  >
                  </audio>
                  <a
                    href={~p"/tenant/recordings/#{rec.id}"}
                    target="_blank"
                    rel="noopener"
                    class="btn btn-ghost btn-square btn-sm"
                    title="Download"
                    aria-label="Download recording"
                  >
                    <.icon name="hero-arrow-down-tray" class="size-5" />
                  </a>
                </div>
              <% %{status: s} when s in ["processing", "recording", "uploading"] -> %>
                <div class="text-xs text-base-content/60 flex items-center gap-2 pl-12">
                  <span class="loading loading-spinner loading-xs"></span> Preparing recording…
                </div>
              <% %{status: "failed"} -> %>
                <div class="text-xs text-error pl-12">Recording could not be processed.</div>
              <% _ -> %>
            <% end %>
          <% end %>
        </li>
      </ul>
    </div>
    """
  end
end
