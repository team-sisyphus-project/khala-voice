defmodule VRWeb.Admin.MFAStepUpLive do
  @moduledoc """
  MFA step-up verification for high-risk admin actions.

  Success does not automatically re-run the previous action. The user returns
  to the account list and must confirm the target and action again.
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
       |> put_flash(:info, "MFA verified. Please select and confirm the action again.")
       |> push_navigate(to: ~p"/_admin/accounts")}
    else
      _ -> {:noreply, assign(socket, error: "The code is incorrect.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={:accounts} title="Verify MFA" subtitle="Protection for high-risk admin actions">
      <div class="vr-card" data-surface="raised" style="max-width: 480px; margin: 0 auto;">
        <div class="vr-card__body">
          <p style="color: var(--text-primary);">
            To continue with admin promotion, privilege revocation, or account deletion, you must verify an authenticator code.
          </p>
          <p class="vr-hint mt-1.5">
            After verifying, you must select the action again from the account list; it will not run automatically.
          </p>

          <div :if={@dev_bypass} class="vr-notice vr-notice--warn mt-4">
            In the development environment, any 6-digit number works.
          </div>

          <div :if={@error} class="vr-notice vr-notice--error mt-4" role="alert">
            {@error}
          </div>

          <form phx-submit="verify" class="flex flex-col gap-4 mt-4">
            <div>
              <label class="vr-label mb-1.5" for="step_up_mfa_code">Verification code</label>
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
              <p class="vr-hint mt-1.5">If your authenticator is unavailable, you can enter a backup code instead.</p>
            </div>

            <button type="submit" data-surface="control" class="vr-btn vr-btn--primary w-full">
              Verify MFA
            </button>
            <.link navigate={~p"/_admin/accounts"} class="vr-btn vr-btn--ghost w-full">
              Cancel
            </.link>
          </form>
        </div>
      </div>
    </.shell>
    """
  end
end
