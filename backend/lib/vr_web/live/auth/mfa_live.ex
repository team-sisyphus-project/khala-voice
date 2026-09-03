defmodule VRWeb.AuthLive.MFALive do
  @moduledoc """
  Sign-in step two — verification code check.

  The password passed, but there is no session yet. Sign-in completes only
  after passing this step too.

  **Does not show which account it is waiting for.** Exposing the email would
  leak, just by reaching this screen, the fact that MFA is enabled on that
  account.
  """

  use VRWeb, :live_view

  import VRWeb.AuthLive.Components

  alias VR.Accounts.MFA

  @impl true
  def mount(_params, session, socket) do
    if session["mfa_pending_account_id"] do
      {:ok,
       socket
       |> assign(page_title: gettext("Verification code"))
       |> assign(dev_bypass: MFA.dev_bypass?()), layout: false}
    else
      {:ok, redirect(socket, to: ~p"/login"), layout: false}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_shell
      title={gettext("Verification code")}
      subtitle={gettext("Enter the 6-digit code from your authenticator app")}
    >
      <div :if={@dev_bypass} class="vr-notice vr-notice--warn mb-4">
        <span class="material-symbols-rounded vr-notice__icon">construction</span>
        <div>{raw(gettext("Development mode — <strong>any 6 digits</strong> will pass."))}</div>
      </div>

      <form action={~p"/login/mfa"} method="post" class="flex flex-col gap-4">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

        <div>
          <label class="vr-label mb-1.5" for="code">{gettext("Code")}</label>
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
            {gettext("Lost your authenticator? You can enter a backup code instead.")}
          </p>
        </div>

        <button type="submit" data-surface="control" class="vr-btn vr-btn--primary w-full">
          {gettext("Verify")}
        </button>
      </form>

      <:footer>
        <.link navigate={~p"/login"} style="color: var(--accent); font-weight: 600;">
          {gettext("Back to sign in")}
        </.link>
      </:footer>
    </.auth_shell>
    """
  end
end
