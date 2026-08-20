defmodule VRWeb.Admin.SecurityLive do
  @moduledoc """
  어드민 2단계 인증 설정.

  **어드민 화면 안에 둔다.** 일반 사용자 설정에는 노출하지 않는다 —
  시스템 어드민은 전체 시스템의 운영자이고, MFA 는 그 역할에 붙은 것이다.
  """

  use VRWeb, :live_view

  import VRWeb.Admin.Components

  alias VR.Accounts.MFA

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(setup: nil, backup_codes: nil, error: nil) |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_account

    assign(socket,
      enabled: account.mfa_enabled,
      enabled_at: account.mfa_enabled_at,
      codes_left: MFA.backup_codes_left(account),
      dev_bypass: MFA.dev_bypass?()
    )
  end

  @impl true
  def handle_event("start_setup", _params, socket) do
    secret = MFA.generate_secret()

    {:noreply,
     assign(socket,
       error: nil,
       backup_codes: nil,
       setup: %{
         secret: secret,
         uri: MFA.provisioning_uri(socket.assigns.current_account, secret),
         readable: MFA.readable_secret(secret)
       }
     )}
  end

  def handle_event("cancel_setup", _params, socket) do
    {:noreply, assign(socket, setup: nil, error: nil)}
  end

  def handle_event("confirm", %{"code" => code}, socket) do
    %{setup: setup, current_account: account} = socket.assigns

    case MFA.enable(account, setup.secret, code) do
      {:ok, updated, codes} ->
        {:noreply,
         socket
         |> assign(current_account: updated, setup: nil, backup_codes: codes, error: nil)
         |> put_flash(:info, "2단계 인증을 켰습니다")
         |> load()}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, error: "코드가 맞지 않습니다. 인증기 앱의 현재 코드를 확인하세요.")}
    end
  end

  def handle_event("disable", %{"code" => code}, socket) do
    case MFA.disable(socket.assigns.current_account, code) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(current_account: updated, error: nil)
         |> put_flash(:info, "2단계 인증을 껐습니다")
         |> load()}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, error: "코드가 맞지 않습니다")}
    end
  end

  def handle_event("dismiss_codes", _params, socket) do
    {:noreply, assign(socket, backup_codes: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={:security} title="보안" subtitle="시스템 어드민 계정의 2단계 인증">
      <.notice
        :if={@dev_bypass}
        kind={:warn}
        icon="construction"
        title="개발 환경입니다"
        class="mb-4"
      >
        여기서는 <strong>6자리 숫자 아무거나</strong> 통과합니다.
        인증기 앱 없이 설정을 확인해 볼 수 있습니다.
        운영에서는 동작하지 않습니다 — 컴파일 시점에 고정됩니다.
      </.notice>

      <.notice :if={@backup_codes} kind={:ok} icon="vpn_key" title="백업 코드" class="mb-4">
        <p>인증기를 잃었을 때 쓰는 일회용 코드입니다. <strong>지금만 볼 수 있습니다.</strong></p>
        <div class="grid grid-cols-2 gap-1.5 mt-3">
          <code
            :for={code <- @backup_codes}
            class="vr-key"
            style="font-size:13px; letter-spacing:.04em;"
          >
            {code}
          </code>
        </div>
        <button class="vr-btn vr-btn--sm vr-btn--outline mt-3" phx-click="dismiss_codes">
          저장했습니다
        </button>
      </.notice>

      <div class="vr-card" data-surface="raised">
        <div class="vr-card__body">
          <div class="flex items-center justify-between gap-4 mb-3">
            <div>
              <h2 class="font-bold" style="color: var(--text-primary);">2단계 인증</h2>
              <p class="vr-hint mt-1">
                <span :if={@enabled}>
                  {Calendar.strftime(@enabled_at, "%Y-%m-%d")} 부터 사용 중 · 백업 코드 {@codes_left}개 남음
                </span>
                <span :if={not @enabled}>
                  비밀번호가 새어도 계정을 지킵니다. 어드민은 켜는 것을 권합니다.
                </span>
              </p>
            </div>
            <span class={["vr-chip", if(@enabled, do: "vr-chip--ok", else: "vr-chip--neutral")]}>
              {if @enabled, do: "켜짐", else: "꺼짐"}
            </span>
          </div>

          <p :if={@error} class="vr-notice vr-notice--error mb-3">{@error}</p>

          <%!-- 설정 시작 전 --%>
          <button
            :if={not @enabled and is_nil(@setup)}
            data-surface="control"
            class="vr-btn vr-btn--primary"
            phx-click="start_setup"
          >
            2단계 인증 켜기
          </button>

          <%!-- 설정 중 --%>
          <div
            :if={@setup}
            class="pt-3"
            style="border-top: var(--hairline-width) solid var(--border-subtle);"
          >
            <ol class="vr-hint" style="line-height:1.9; padding-left:18px; margin-bottom:14px;">
              <li>인증기 앱(1Password · Google Authenticator 등)을 엽니다</li>
              <li>아래 키를 등록합니다</li>
              <li>앱이 보여주는 6자리 코드를 입력합니다</li>
            </ol>

            <div class="mb-3">
              <label class="vr-label mb-1.5">설정 키</label>
              <code
                class="vr-key"
                style="display:block; padding:12px; background: var(--surface-inset); border-radius: var(--radius-md); font-size:14px; letter-spacing:.08em; word-break:break-all;"
              >
                {@setup.readable}
              </code>
              <p class="vr-hint mt-1.5" style="font-size:12px;">
                QR 로 등록하려면 이 주소를 씁니다:
                <span class="vr-key" style="word-break:break-all;">{@setup.uri}</span>
              </p>
            </div>

            <form phx-submit="confirm" class="flex gap-2 items-end">
              <div style="flex:1">
                <label class="vr-label mb-1.5" for="mfa_code">6자리 코드</label>
                <input
                  type="text"
                  id="mfa_code"
                  name="code"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  maxlength="6"
                  required
                  data-surface="sunken"
                  class="vr-input"
                  style="letter-spacing:.3em; text-align:center;"
                />
              </div>
              <button type="submit" data-surface="control" class="vr-btn vr-btn--primary">확인</button>
              <button
                type="button"
                data-surface="control"
                class="vr-btn vr-btn--ghost"
                phx-click="cancel_setup"
              >
                취소
              </button>
            </form>
          </div>

          <%!-- 켜져 있을 때 --%>
          <form
            :if={@enabled}
            phx-submit="disable"
            class="flex gap-2 items-end pt-3"
            style="border-top: var(--hairline-width) solid var(--border-subtle);"
          >
            <div style="flex:1">
              <label class="vr-label mb-1.5" for="disable_code">끄려면 현재 코드를 입력하세요</label>
              <input
                type="text"
                id="disable_code"
                name="code"
                inputmode="numeric"
                autocomplete="one-time-code"
                required
                data-surface="sunken"
                class="vr-input"
                style="letter-spacing:.3em; text-align:center;"
              />
            </div>
            <button
              type="submit"
              data-surface="control"
              class="vr-btn vr-btn--ghost"
              style="color: var(--status-error);"
            >
              끄기
            </button>
          </form>
        </div>
      </div>
    </.shell>
    """
  end
end
