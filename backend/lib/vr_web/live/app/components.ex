defmodule VRWeb.AppLive.Components do
  @moduledoc "Shared shell for the signed-in app screens."
  use Phoenix.Component
  use VRWeb, :verified_routes
  use Gettext, backend: VRWeb.Gettext

  attr :current_account, :map, required: true
  attr :active, :atom, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  # Back destination for detail screens. When given, a **round button on the left**
  # appears in the top bar and the title moves into it. Do not set it on the four
  # top-level tabs (meetings, archive, friends, settings).
  attr :back, :string, default: nil
  slot :inner_block, required: true
  slot :actions

  @doc """
  Shell for signed-in screens.

  **Uses the same markup as the web app (React `AppShell.tsx`)** — `mobile-app`
  container + top bar + `mobile-screen` + bottom `.bottom-nav`. The class names
  are the contract (the CSS lives in one place, `packages/ui-styles/`), so
  renaming them breaks both sides at once.

  This module used to render its own top text navigation (meetings, friends,
  settings). With two navigations in the same app, no one can tell which is
  the real one.
  """
  def app_shell(assigns) do
    ~H"""
    <main class={["mobile-app", if(@back, do: "is-detail", else: "is-tabs")]}>
      <header class={[
        "mobile-top-app-bar",
        if(@back, do: "mobile-top-app-bar--detail", else: "mobile-top-app-bar--tabs")
      ]}>
        <div class="mobile-top-app-bar__row">
          <.link
            :if={@back}
            navigate={@back}
            class="mobile-top-app-bar__icon-button"
            aria-label={gettext("Back")}
          >
            <span aria-hidden="true" class="material-symbols-rounded mobile-icon">arrow_back</span>
          </.link>

          <div :if={@back} class="mobile-top-app-bar__titles">
            <h1 class="mobile-top-app-bar__title">{@title}</h1>
            <p :if={@subtitle} class="mobile-top-app-bar__subtitle">{@subtitle}</p>
          </div>

          <div :if={@back && @actions != []} class="mobile-top-app-bar__action">
            {render_slot(@actions)}
          </div>
        </div>
      </header>

      <div class="mobile-screen">
        <div class="mobile-screen__inner">
          <%!-- On top-level tabs the title sits at the top of the body, with actions on the **same row**. --%>
          <header
            :if={is_nil(@back)}
            class={["mobile-page-header", @actions != [] && "mobile-page-header--row"]}
          >
            <div style="min-width: 0;">
              <h1 class="mobile-page-header__title">{@title}</h1>
              <p :if={@subtitle} class="mobile-page-header__subtitle">{@subtitle}</p>
            </div>
            <div :if={@actions != []} class="vr-page-actions">{render_slot(@actions)}</div>
          </header>

          <.email_notice account={@current_account} />
          {render_slot(@inner_block)}
        </div>
      </div>

      <.bottom_nav active={@active} />
    </main>
    """
  end

  attr :active, :atom, required: true

  @doc """
  Bottom tabs. The **same four slots** as the web app (meetings, archive, friends, settings).

  There is no admin link here. The system admin area is reached **only by typing
  the URL directly**. Putting it in the menu would (a) reveal to regular users
  that such a screen exists and (b) make it easy for operators themselves to tap
  it by accident during normal use.
  Unauthorized requests get a 404 from the server, not a 403.
  """
  def bottom_nav(assigns) do
    ~H"""
    <nav class="bottom-nav" aria-label={gettext("Main menu")}>
      <.nav_tab
        active={@active}
        id={:meetings}
        path="/go/meetings"
        icon="mic"
        label={gettext("Meetings")}
      />
      <.nav_tab
        active={@active}
        id={:archive}
        path="/go/archive"
        icon="inventory_2"
        label={gettext("Archive")}
      />
      <.nav_tab
        active={@active}
        id={:friends}
        path={~p"/friends"}
        icon="group"
        label={gettext("Friends")}
      />
      <.nav_tab
        active={@active}
        id={:settings}
        path="/go/settings"
        icon="settings"
        label={gettext("Settings")}
      />
    </nav>
    """
  end

  attr :active, :atom, required: true
  attr :id, :atom, required: true
  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  def nav_tab(assigns) do
    ~H"""
    <.link
      href={@path}
      aria-current={if @active == @id, do: "page", else: nil}
      data-active={if @active == @id, do: "true", else: nil}
    >
      <span aria-hidden="true" class="material-symbols-rounded mobile-icon">{@icon}</span>
      <span>{@label}</span>
    </.link>
    """
  end

  attr :account, :map, required: true

  def email_notice(assigns) do
    ~H"""
    <div :if={is_nil(@account.confirmed_at)} class="mobile-inline-failure vr-notice--warn">
      <span aria-hidden="true" class="material-symbols-rounded mobile-icon">mark_email_unread</span>
      <div>
        <strong>{gettext("Confirm your email")}</strong>
        <p class="vr-note vr-note--small">
          {gettext(
            "Open the link in the email we sent you. Some features are limited until you confirm."
          )}
        </p>
      </div>
    </div>
    """
  end

  @doc "Empty state."
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, default: nil
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class="mobile-empty-state">
      <span aria-hidden="true" class="material-symbols-rounded mobile-icon">{@icon}</span>
      <p class="mobile-empty-state__title">{@title}</p>
      <p :if={@desc} class="mobile-empty-state__description">{@desc}</p>
      <div :if={@inner_block != []}>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc "Avatar showing the first letter of the name."
  attr :account, :map, required: true
  attr :size, :integer, default: 36

  def avatar(assigns) do
    assigns = assign(assigns, :initial, initial(assigns.account))

    ~H"""
    <span
      class="inline-flex items-center justify-center rounded-full shrink-0 font-bold text-white"
      style={"width: #{@size}px; height: #{@size}px; background: #{color_for(@account)}; font-size: #{round(@size * 0.42)}px;"}
    >
      {@initial}
    </span>
    """
  end

  defp initial(%{name: name}) when is_binary(name) and name != "",
    do: String.first(name) |> String.upcase()

  defp initial(%{email: email}) when is_binary(email), do: String.first(email) |> String.upcase()
  defp initial(_), do: "?"

  # Hash the account ID to pin the color. The same person always gets the same color.
  defp color_for(%{id: id}) when is_binary(id) do
    palette = ~w(#f87171 #60a5fa #4ade80 #c084fc #facc15 #2dd4bf #f472b6 #818cf8 #fb923c #f97316)
    Enum.at(palette, :erlang.phash2(id, length(palette)))
  end

  defp color_for(_), do: "#9ca3af"
end
