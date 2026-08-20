defmodule VRWeb.AuthLive.MFALive do
  @moduledoc """
  로그인 2단계 — 인증 코드 확인.

  비밀번호는 통과했지만 아직 세션이 없다. 여기까지 통과해야 로그인된다.

  **어느 계정을 기다리는지 화면에 보여주지 않는다.** 이메일을 노출하면
  이 화면에 도달한 것만으로 그 계정에 MFA 가 걸려 있다는 사실이 새어 나간다.
  """

  use VRWeb, :live_view

  import VRWeb.AuthLive.Components

  alias VR.Accounts.MFA

  @impl true
  def mount(_params, session, socket) do
    if session["mfa_pending_account_id"] do
      {:ok,
       socket
       |> assign(page_title: "인증 코드")
       |> assign(dev_bypass: MFA.dev_bypass?()), layout: false}
    else
      {:ok, redirect(socket, to: ~p"/login"), layout: false}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_shell title="인증 코드" subtitle="인증기 앱의 6자리 코드를 입력하세요">
      <div :if={@dev_bypass} class="vr-notice vr-notice--warn mb-4">
        <span class="material-symbols-rounded vr-notice__icon">construction</span>
        <div>개발 환경이라 <strong>6자리 숫자 아무거나</strong> 통과합니다.</div>
      </div>

      <form action={~p"/login/mfa"} method="post" class="flex flex-col gap-4">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

        <div>
          <label class="vr-label mb-1.5" for="code">코드</label>
          <input
            type="text"
            id="code"
            name="code"
            inputmode="numeric"
            autocomplete="one-time-code"
            autofocus
            required
            data-surface="sunken"
            class="vr-input"
            style="letter-spacing:.3em; text-align:center; font-size:18px;"
          />
          <p class="vr-hint mt-1.5" style="font-size:12px;">
            인증기를 잃었다면 백업 코드를 입력해도 됩니다.
          </p>
        </div>

        <button type="submit" data-surface="control" class="vr-btn vr-btn--primary w-full">확인</button>
      </form>

      <:footer>
        <.link navigate={~p"/login"} style="color: var(--accent); font-weight: 600;">
          다시 로그인
        </.link>
      </:footer>
    </.auth_shell>
    """
  end
end
