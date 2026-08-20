defmodule VRWeb.AuthLive.MFAEnrollLive do
  @moduledoc """
  로그인 2단계 — **2단계 인증 등록**.

  **출처: devkanban** `lib/manualsquad_web/controllers/session_controller.ex` 의
  `enroll/2` · `verify_enroll/2` 와 `session_html/enroll.html.heex`.
  같은 문제(어드민 MFA 데드락)를 같은 방법으로 푼다 — 마크업은 이 앱 것이다.

  ## 왜 로그인 구역에 있나

  2단계 인증이 **의무**인 계정(시스템 어드민)이 아직 켜지 않았다면, 켜기 전에는
  어디에도 못 들어간다. 그런데 켜는 화면이 어드민 구역 안에 있으면 **자기 자신을
  막는 문이 된다** — 신규 어드민은 DB 를 직접 건드리지 않는 한 영원히 들어갈 수 없다.

  그래서 이 화면은 로그인 흐름의 일부다. 비밀번호는 통과했고 세션은 아직 없는
  상태에서, 등록을 마쳐야 로그인이 완료된다.

  ## 화면에 계정을 드러내지 않는다

  `MFALive` 와 같은 이유다 — 이 화면에 도달한 것만으로 그 계정이 어드민이라는
  사실이 새어 나가면 안 된다. 이메일 대신 발급용 URI 만 보여준다.
  """

  use VRWeb, :live_view

  import VRWeb.AuthLive.Components

  alias VR.Accounts
  alias VR.Accounts.MFA

  @impl true
  def mount(_params, session, socket) do
    with id when is_binary(id) <- session["mfa_pending_account_id"],
         account when not is_nil(account) <- Accounts.get_account(id) do
      # 비밀키는 **한 번만** 만든다. 코드가 틀렸다고 새로 만들면 사용자가 방금
      # 스캔한 QR 이 무효가 된다 (devkanban `build_totp_setup_for_secret` 의 이유).
      secret = MFA.generate_secret()

      {:ok,
       socket
       |> assign(page_title: "2단계 인증 설정")
       |> assign(secret: secret)
       |> assign(encoded_secret: Base.encode32(secret, padding: false))
       |> assign(uri: MFA.provisioning_uri(account, secret))
       |> assign(dev_bypass: MFA.dev_bypass?()), layout: false}
    else
      _ -> {:ok, redirect(socket, to: ~p"/login"), layout: false}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_shell
      title="2단계 인증 설정"
      subtitle="시스템 어드민은 2단계 인증을 켜야 들어갈 수 있습니다"
    >
      <div :if={@dev_bypass} class="mobile-inline-failure vr-notice--warn">
        <span aria-hidden="true" class="material-symbols-rounded mobile-icon">construction</span>
        <div>개발 환경이라 <strong>6자리 숫자 아무거나</strong> 통과합니다.</div>
      </div>

      <ol
        class="vr-note vr-note--small"
        style="margin: 0 0 12px; padding-left: 18px; line-height: 1.9;"
      >
        <li>인증기 앱(Google Authenticator · 1Password 등)을 연다</li>
        <li>아래 키를 등록한다</li>
        <li>앱이 보여주는 6자리 코드를 입력한다</li>
      </ol>

      <%!-- QR 라이브러리를 새로 들이지 않는다. 대부분의 인증기 앱은 키를 직접
            입력할 수 있고, 그것만으로 등록이 끝난다. --%>
      <div class="vr-enroll-secret">
        <code>{@encoded_secret}</code>
        <button
          type="button"
          class="mobile-button mobile-button--secondary mobile-button--fit"
          phx-hook="CopyToClipboard"
          id="copy-secret"
          data-copy={@encoded_secret}
        >
          복사
        </button>
      </div>

      <p class="vr-note vr-note--small" style="margin: 8px 0 16px;">
        앱에서 <strong>수동 입력</strong>을 고르고 이 키를 넣으세요.
        계정 이름은 자유롭게 정해도 됩니다.
      </p>

      <form action={~p"/login/mfa/enroll"} method="post" class="flex flex-col gap-4">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <input type="hidden" name="secret" value={@encoded_secret} />

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
        </div>

        <button type="submit" data-surface="control" class="vr-btn vr-btn--primary w-full">
          켜고 계속
        </button>
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
