defmodule VRWeb.AppLive.Components do
  @moduledoc "로그인 후 앱 화면의 공용 껍데기."
  use Phoenix.Component
  use VRWeb, :verified_routes

  attr :current_account, :map, required: true
  attr :active, :atom, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  # 뎁스 화면의 뒤로가기 목적지. 주면 상단에 **좌측 원형 버튼**이 서고, 제목은
  # 상단바가 든다. 최상위 네 탭(회의·아카이브·친구·설정)에는 주지 않는다.
  attr :back, :string, default: nil
  slot :inner_block, required: true
  slot :actions

  @doc """
  로그인 후 화면의 껍데기.

  **웹앱(React `AppShell.tsx`)과 같은 마크업을 쓴다** — `mobile-app` 컨테이너 +
  상단바 + `mobile-screen` + 하단 `.bottom-nav`. 클래스 이름이 곧 계약이라
  (CSS 가 `packages/ui-styles/` 한 곳에 있다) 이름을 바꾸면 양쪽이 같이 깨진다.

  예전에는 여기만 상단 텍스트 내비게이션(회의·친구·설정)을 그렸다. 같은 앱에
  내비게이션이 두 벌이면 어느 쪽이 진짜인지 알 수 없다.
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
            aria-label="뒤로"
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
          <%!-- 최상위 탭은 제목이 본문 맨 위에 붙고, 액션이 **같은 줄**에 선다. --%>
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
  하단 탭. 웹앱과 **같은 네 칸**이다 (회의 · 아카이브 · 친구 · 설정).

  어드민 링크를 두지 않는다. 시스템 어드민은 **주소를 직접 입력해서만** 들어간다.
  메뉴에 두면 (a) 일반 사용자에게 그런 화면이 있다는 사실이 드러나고
  (b) 운영자 본인도 평소 화면에서 실수로 누르기 쉽다.
  권한 없는 요청에는 서버가 403 이 아니라 404 를 준다.
  """
  def bottom_nav(assigns) do
    ~H"""
    <nav class="bottom-nav" aria-label="주 메뉴">
      <.nav_tab active={@active} id={:meetings} path="/go/meetings" icon="mic" label="회의" />
      <.nav_tab
        active={@active}
        id={:archive}
        path="/go/archive"
        icon="inventory_2"
        label="아카이브"
      />
      <.nav_tab active={@active} id={:friends} path={~p"/friends"} icon="group" label="친구" />
      <.nav_tab active={@active} id={:settings} path="/go/settings" icon="settings" label="설정" />
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
        <strong>이메일 확인이 필요합니다</strong>
        <p class="vr-note vr-note--small">
          보내드린 메일의 링크를 열어 주세요. 확인 전에는 일부 기능이 제한될 수 있습니다.
        </p>
      </div>
    </div>
    """
  end

  @doc "빈 상태."
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

  @doc "이름 첫 글자 아바타."
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

  # 계정 ID를 해시해 색을 고정한다. 같은 사람은 항상 같은 색이 나온다.
  defp color_for(%{id: id}) when is_binary(id) do
    palette = ~w(#f87171 #60a5fa #4ade80 #c084fc #facc15 #2dd4bf #f472b6 #818cf8 #fb923c #f97316)
    Enum.at(palette, :erlang.phash2(id, length(palette)))
  end

  defp color_for(_), do: "#9ca3af"
end
