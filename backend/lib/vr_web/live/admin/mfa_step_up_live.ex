defmodule VRWeb.Admin.MFAStepUpLive do
  @moduledoc """
  고위험 어드민 작업을 위한 MFA 단계상승 인증.

  성공해도 이전 작업을 자동 실행하지 않는다. 계정 목록으로 돌아간 뒤 대상과
  작업을 사용자가 다시 확인해야 한다.
  """

  use VRWeb, :live_view

  import VRWeb.Admin.Components

  alias VR.Accounts
  alias VR.Accounts.MFA

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, dev_bypass: MFA.dev_bypass?(), error: nil)}
  end

  @impl true
  def handle_event("verify", %{"code" => code}, socket) do
    account = socket.assigns.current_account
    session = socket.assigns.current_session

    with :ok <- MFA.verify(account, code),
         {:ok, updated_session} <- Accounts.mark_session_mfa_verified(session, account.id) do
      {:noreply,
       socket
       |> assign(current_session: updated_session)
       |> put_flash(:info, "MFA 확인을 마쳤습니다. 작업을 다시 선택해 확인해 주세요.")
       |> push_navigate(to: ~p"/_admin/accounts")}
    else
      _ -> {:noreply, assign(socket, error: "코드가 맞지 않습니다")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={:accounts} title="MFA 확인" subtitle="고위험 관리자 작업 보호">
      <div class="vr-card" data-surface="raised" style="max-width: 480px; margin: 0 auto;">
        <div class="vr-card__body">
          <p style="color: var(--text-primary);">
            어드민 승격, 권한 회수, 계정 삭제를 계속하려면 인증기 코드를 확인해야 합니다.
          </p>
          <p class="vr-hint mt-1.5">
            확인 후 계정 목록에서 작업을 다시 선택해야 하며, 작업은 자동으로 실행되지 않습니다.
          </p>

          <div :if={@dev_bypass} class="vr-notice vr-notice--warn mt-4">
            개발 환경에서는 6자리 숫자 아무거나 사용할 수 있습니다.
          </div>

          <div :if={@error} class="vr-notice vr-notice--error mt-4" role="alert">
            {@error}
          </div>

          <form phx-submit="verify" class="flex flex-col gap-4 mt-4">
            <div>
              <label class="vr-label mb-1.5" for="step_up_mfa_code">인증 코드</label>
              <input
                type="text"
                id="step_up_mfa_code"
                name="code"
                inputmode="numeric"
                autocomplete="one-time-code"
                autofocus
                required
                data-surface="sunken"
                class="vr-input"
                style="letter-spacing:.3em; text-align:center; font-size:18px;"
              />
              <p class="vr-hint mt-1.5">인증기를 사용할 수 없다면 백업 코드를 입력해도 됩니다.</p>
            </div>

            <button type="submit" data-surface="control" class="vr-btn vr-btn--primary w-full">
              MFA 확인
            </button>
            <.link navigate={~p"/_admin/accounts"} class="vr-btn vr-btn--ghost w-full">
              취소
            </.link>
          </form>
        </div>
      </div>
    </.shell>
    """
  end
end
