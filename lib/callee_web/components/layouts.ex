defmodule CalleeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CalleeWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_role, :string, default: nil
  attr :current_user, :map, default: nil
  attr :active, :atom, default: nil
  attr :missed, :integer, default: 0
  attr :wide, :boolean, default: false
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :tabs, tabs(assigns.current_role))

    ~H"""
    <div class="min-h-dvh flex flex-col bg-base-200/60">
      <header class="navbar bg-base-100/90 backdrop-blur border-b border-base-300 px-3 sm:px-6 sticky top-0 z-30 pt-[env(safe-area-inset-top)]">
        <div class="flex-1 flex items-center gap-2 min-w-0">
          <img src={~p"/images/icon.svg"} class="size-8 rounded-lg" alt="" />
          <span class="font-bold text-lg">Callee</span>
          <span
            :if={@current_role}
            class="badge badge-ghost badge-sm capitalize hidden sm:inline-flex"
          >
            {@current_role}
          </span>
        </div>
        <nav :if={@tabs != []} class="hidden sm:flex items-center gap-1 mr-2" aria-label="Main">
          <.link
            :for={{key, label, icon, path} <- @tabs}
            navigate={path}
            class={["btn btn-sm gap-1.5", if(@active == key, do: "btn-primary", else: "btn-ghost")]}
            aria-current={@active == key && "page"}
          >
            <.icon name={icon} class="size-4" /> {label}
            <span :if={key == :calls and @missed > 0} class="badge badge-error badge-xs">
              {@missed}
            </span>
          </.link>
        </nav>
        <div class="flex-none flex items-center gap-1">
          <div
            :if={@current_role in ["tenant", "client"]}
            id="conn-status"
            phx-update="ignore"
            class="badge badge-ghost gap-1.5 h-7"
            role="status"
            aria-live="polite"
          >
            <span class="dot size-2 rounded-full bg-base-300"></span><span class="label text-xs hidden sm:inline">Connecting</span>
          </div>
          <div class="hidden sm:block"><.theme_toggle /></div>
          <.link
            :if={@current_role}
            href={~p"/logout"}
            method="delete"
            class="btn btn-sm btn-ghost btn-square"
            title="Sign out"
            aria-label="Sign out"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-5" />
          </.link>
        </div>
      </header>

      <div
        id="offline-banner"
        phx-update="ignore"
        class="hidden bg-warning text-warning-content text-sm text-center py-1.5 px-4"
      >
        <.icon name="hero-signal-slash" class="size-4 align-text-bottom" />
        You're offline. Calls can't reach you until you reconnect.
      </div>
      <div
        :if={@current_role in ["tenant", "client"]}
        id="pwa-banner"
        phx-update="ignore"
        class="hidden"
      >
      </div>

      <main class={[
        "flex-1 px-3 sm:px-6 pt-4 sm:pt-6",
        if(@tabs != [], do: "pb-28 sm:pb-10", else: "pb-10")
      ]}>
        <div class={["mx-auto space-y-4", if(@wide, do: "max-w-6xl", else: "max-w-3xl")]}>
          {render_slot(@inner_block)}
        </div>
      </main>

      <nav
        :if={@tabs != []}
        class="sm:hidden fixed bottom-0 inset-x-0 z-30 bg-base-100/95 backdrop-blur border-t border-base-300 pb-[env(safe-area-inset-bottom)]"
        aria-label="Main"
      >
        <div class="grid" style={"grid-template-columns: repeat(#{length(@tabs)}, minmax(0, 1fr))"}>
          <.link
            :for={{key, label, icon, path} <- @tabs}
            navigate={path}
            class={[
              "flex flex-col items-center gap-0.5 py-2 text-xs relative",
              if(@active == key, do: "text-primary font-semibold", else: "text-base-content/60")
            ]}
            aria-current={@active == key && "page"}
          >
            <.icon name={if @active == key, do: icon <> "-solid", else: icon} class="size-6" />
            {label}
            <span
              :if={key == :calls and @missed > 0}
              class="badge badge-error badge-xs absolute top-1 left-1/2 ml-2"
            >
              {@missed}
            </span>
          </.link>
        </div>
      </nav>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp tabs("tenant"),
    do: [
      {:contacts, "Contacts", "hero-users", ~p"/tenant"},
      {:groups, "Groups", "hero-user-group", ~p"/tenant/groups"},
      {:calls, "Calls", "hero-phone", ~p"/tenant/calls"},
      {:settings, "Settings", "hero-cog-6-tooth", ~p"/tenant/settings"}
    ]

  defp tabs("client"),
    do: [
      {:contacts, "Contacts", "hero-users", ~p"/app"},
      {:calls, "Calls", "hero-phone", ~p"/app/calls"},
      {:settings, "Settings", "hero-cog-6-tooth", ~p"/app/settings"}
    ]

  # Tailwind safelist for dynamic icons: hero-users-solid hero-user-group-solid hero-phone-solid hero-cog-6-tooth-solid
  defp tabs(_), do: []

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
