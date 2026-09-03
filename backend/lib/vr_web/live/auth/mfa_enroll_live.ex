defmodule VRWeb.AuthLive.MFAEnrollLive do
  @moduledoc """
  Sign-in step two — **two-factor authentication enrollment**.

  **Source: devkanban** — `enroll/2` and `verify_enroll/2` in
  `lib/manualsquad_web/controllers/session_controller.ex`, plus
  `session_html/enroll.html.heex`. Solves the same problem (the admin MFA
  deadlock) the same way — the markup is this app's own.

  ## Why this lives in the sign-in area

  An account for which two-factor authentication is **mandatory** (system
  admins) can get in nowhere until it is turned on. But if the enrollment
  screen sits inside the admin area, it becomes **a door that locks itself** —
  a new admin can never get in without touching the DB directly.

  So this screen is part of the sign-in flow. The password has passed and
  there is no session yet; sign-in completes only once enrollment is done.

  ## The screen does not reveal the account

  Same reason as `MFALive` — merely reaching this screen must not leak the
  fact that the account is an admin. We show only the provisioning URI, not
  the email.
  """

  use VRWeb, :live_view

  import VRWeb.AuthLive.Components

  alias VR.Accounts
  alias VR.Accounts.MFA

  @impl true
  def mount(_params, session, socket) do
    with id when is_binary(id) <- session["mfa_pending_account_id"],
         account when not is_nil(account) <- Accounts.get_account(id) do
      # Generate the secret **only once**. Regenerating it because a code was
      # wrong would invalidate the QR the user just scanned (the reason for
      # devkanban's `build_totp_setup_for_secret`).
      secret = MFA.generate_secret()

      {:ok,
       socket
       |> assign(page_title: gettext("Set up two-factor authentication"))
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
      title={gettext("Set up two-factor authentication")}
      subtitle={gettext("System admins must turn on two-factor authentication to sign in")}
    >
      <div :if={@dev_bypass} class="mobile-inline-failure vr-notice--warn">
        <span aria-hidden="true" class="material-symbols-rounded mobile-icon">construction</span>
        <div>{raw(gettext("Development mode — <strong>any 6 digits</strong> will pass."))}</div>
      </div>

      <ol
        class="vr-note vr-note--small"
        style="margin: 0 0 12px; padding-left: 18px; line-height: 1.9;"
      >
        <li>{gettext("Open an authenticator app (Google Authenticator, 1Password, etc.)")}</li>
        <li>{gettext("Add the key below")}</li>
        <li>{gettext("Enter the 6-digit code the app shows")}</li>
      </ol>

      <%!-- We don't pull in a QR library. Most authenticator apps accept the
            key entered by hand, and that alone completes enrollment. --%>
      <div class="vr-enroll-secret">
        <code>{@encoded_secret}</code>
        <button
          type="button"
          class="mobile-button mobile-button--secondary mobile-button--fit"
          phx-hook="CopyToClipboard"
          id="copy-secret"
          data-copy={@encoded_secret}
        >
          {gettext("Copy")}
        </button>
      </div>

      <p class="vr-note vr-note--small" style="margin: 8px 0 16px;">
        {raw(
          gettext(
            "In the app, choose <strong>manual entry</strong> and paste this key. You can name the account anything."
          )
        )}
      </p>

      <form action={~p"/login/mfa/enroll"} method="post" class="flex flex-col gap-4">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <input type="hidden" name="secret" value={@encoded_secret} />

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
        </div>

        <button type="submit" data-surface="control" class="vr-btn vr-btn--primary w-full">
          {gettext("Turn on and continue")}
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
