defmodule VRWeb.Admin.Components do
  @moduledoc """
  Shared components for the admin screens.

  Styling follows the sisyphus design system (`assets/css/tokens.css`).
  Use `.vr-*` classes or token variables instead of color literals.
  """
  use Phoenix.Component
  use VRWeb, :verified_routes

  attr :active, :atom, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true
  slot :actions

  def shell(assigns) do
    ~H"""
    <div class="min-h-screen" style="background: var(--surface-canvas);">
      <header
        class="flex items-center gap-2 px-6 h-14"
        style="background: var(--surface-1);"
        style="border-bottom: 1px solid var(--border-subtle);"
      >
        <span class="text-[17px] font-bold" style="color: var(--text-primary);">
          KHALA VOICE
        </span>
        <span class="vr-chip vr-chip--neutral">admin</span>
      </header>

      <div class="flex">
        <aside
          class="w-56 shrink-0  p-3"
          style="border-right: 1px solid var(--border-subtle); min-height: calc(100vh - 3.5rem);"
        >
          <nav class="flex flex-col gap-0.5">
            <.nav_item active={@active} id={:dashboard} path={~p"/_admin"} label="Dashboard" />
            <.nav_item active={@active} id={:accounts} path={~p"/_admin/accounts"} label="Accounts" />
            <.nav_item active={@active} id={:security} path={~p"/_admin/security"} label="Security" />
            <.nav_item active={@active} id={:billing} path={~p"/_admin/billing"} label="Billing" />
            <span class="vr-nav__title">Settings</span>
            <.nav_item
              active={@active}
              id={:storage}
              path={~p"/_admin/settings/storage"}
              label="Storage"
            />
            <.nav_item
              active={@active}
              id={:stt}
              path={~p"/_admin/settings/stt"}
              label="Transcription (STT)"
            />
            <.nav_item active={@active} id={:llm} path={~p"/_admin/llm"} label="LLM" />
            <.nav_item
              active={@active}
              id={:social}
              path={~p"/_admin/social"}
              label="Social sign-in"
            />
            <.nav_item active={@active} id={:mail} path={~p"/_admin/settings/mail"} label="Mail" />
            <.nav_item
              active={@active}
              id={:push}
              path={~p"/_admin/settings/push"}
              label="Web push"
            />
            <.nav_item
              active={@active}
              id={:policy}
              path={~p"/_admin/settings/policy"}
              label="Policy"
            />
            <.nav_item active={@active} id={:app} path={~p"/_admin/settings/app"} label="App" />
          </nav>
        </aside>

        <main class="vr-admin__main">
          <header class="mb-6 flex items-start justify-between gap-4">
            <div>
              <h1 class="text-[26px] font-bold" style="color: var(--text-primary);">{@title}</h1>
              <p :if={@subtitle} class="vr-hint mt-1.5">{@subtitle}</p>
            </div>
            <div class="flex gap-2 shrink-0">{render_slot(@actions)}</div>
          </header>
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  attr :active, :atom, required: true
  attr :id, :atom, required: true
  attr :path, :string, required: true
  attr :label, :string, required: true

  def nav_item(assigns) do
    ~H"""
    <.link navigate={@path} class={["vr-nav__item", @active == @id && "vr-nav__item--active"]}>
      {@label}
    </.link>
    """
  end

  @doc "Notice banner. sisyphus uses a pastel background with dark text instead of a solid fill."
  attr :kind, :atom, default: :info, values: [:info, :warn, :error, :ok]
  attr :icon, :string, default: nil
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def notice(assigns) do
    ~H"""
    <div class={["vr-notice", "vr-notice--#{@kind}", @class]}>
      <span :if={@icon} class="material-symbols-rounded vr-notice__icon">{@icon}</span>
      <div class="min-w-0">
        <div :if={@title} class="vr-notice__title">{@title}</div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "Value source badge — whether it came from the DB or an environment variable."
  attr :source, :atom, required: true
  attr :present, :boolean, default: true

  def source_badge(assigns) do
    ~H"""
    <span :if={@present and @source == :db} class="vr-chip vr-chip--ok">DB</span>
    <span :if={@present and @source == :env} class="vr-chip vr-chip--info">Env var</span>
    <span :if={not @present} class="vr-chip vr-chip--neutral">Not set</span>
    """
  end

  @doc "Warning banner for feature readiness."
  attr :statuses, :list, required: true

  def readiness_banner(assigns) do
    assigns = assign(assigns, :blocked, Enum.reject(assigns.statuses, & &1.ready))

    ~H"""
    <.notice
      :if={@blocked != []}
      kind={:warn}
      icon="pending"
      title="Some features are not working yet"
      class="mb-4"
    >
      <ul class="mt-1.5 space-y-1">
        <li :for={s <- @blocked}>
          <span class="font-semibold">{feature_label(s.feature)}</span>
          — requires: {s.missing |> Enum.map(& &1.label) |> Enum.join(", ")}
        </li>
      </ul>
    </.notice>
    """
  end

  def feature_label(:storage), do: "Recording upload"
  def feature_label(:transcription), do: "Transcription"
  def feature_label(:summary), do: "AI summary"
  def feature_label(:mail), do: "Mail delivery"
  def feature_label(:push), do: "Web push"
  def feature_label(other), do: to_string(other)
end
