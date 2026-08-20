defmodule VRWeb.Admin.Components do
  @moduledoc """
  어드민 화면 공용 컴포넌트.

  스타일은 sisyphus 디자인 시스템을 따른다 (`assets/css/tokens.css`).
  색 리터럴을 쓰지 말고 `.vr-*` 클래스나 토큰 변수를 쓴다.
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
            <.nav_item active={@active} id={:dashboard} path={~p"/_admin"} label="대시보드" />
            <.nav_item active={@active} id={:accounts} path={~p"/_admin/accounts"} label="계정" />
            <.nav_item active={@active} id={:security} path={~p"/_admin/security"} label="보안" />
            <.nav_item active={@active} id={:billing} path={~p"/_admin/billing"} label="요금" />
            <span class="vr-nav__title">설정</span>
            <.nav_item
              active={@active}
              id={:storage}
              path={~p"/_admin/settings/storage"}
              label="스토리지"
            />
            <.nav_item
              active={@active}
              id={:stt}
              path={~p"/_admin/settings/stt"}
              label="전사 (STT)"
            />
            <.nav_item active={@active} id={:llm} path={~p"/_admin/llm"} label="LLM" />
            <.nav_item
              active={@active}
              id={:social}
              path={~p"/_admin/social"}
              label="소셜 로그인"
            />
            <.nav_item active={@active} id={:mail} path={~p"/_admin/settings/mail"} label="메일" />
            <.nav_item
              active={@active}
              id={:push}
              path={~p"/_admin/settings/push"}
              label="웹 푸시"
            />
            <.nav_item
              active={@active}
              id={:policy}
              path={~p"/_admin/settings/policy"}
              label="정책"
            />
            <.nav_item active={@active} id={:app} path={~p"/_admin/settings/app"} label="앱" />
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

  @doc "알림 배너. sisyphus는 단색 채움 대신 파스텔 배경 + 진한 글자를 쓴다."
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

  @doc "값의 출처 배지 — DB에서 왔는지 환경변수에서 왔는지."
  attr :source, :atom, required: true
  attr :present, :boolean, default: true

  def source_badge(assigns) do
    ~H"""
    <span :if={@present and @source == :db} class="vr-chip vr-chip--ok">DB</span>
    <span :if={@present and @source == :env} class="vr-chip vr-chip--info">환경변수</span>
    <span :if={not @present} class="vr-chip vr-chip--neutral">미설정</span>
    """
  end

  @doc "기능 준비 상태 경고 배너."
  attr :statuses, :list, required: true

  def readiness_banner(assigns) do
    assigns = assign(assigns, :blocked, Enum.reject(assigns.statuses, & &1.ready))

    ~H"""
    <.notice
      :if={@blocked != []}
      kind={:warn}
      icon="pending"
      title="아직 동작하지 않는 기능이 있습니다"
      class="mb-4"
    >
      <ul class="mt-1.5 space-y-1">
        <li :for={s <- @blocked}>
          <span class="font-semibold">{feature_label(s.feature)}</span>
          — 필요: {s.missing |> Enum.map(& &1.label) |> Enum.join(", ")}
        </li>
      </ul>
    </.notice>
    """
  end

  def feature_label(:storage), do: "녹음 업로드"
  def feature_label(:transcription), do: "전사"
  def feature_label(:summary), do: "AI 요약"
  def feature_label(:mail), do: "메일 발송"
  def feature_label(:push), do: "웹 푸시"
  def feature_label(other), do: to_string(other)
end
