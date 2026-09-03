defmodule VRWeb.Admin.SecurityLive do
  @moduledoc """
  Two-factor authentication settings for admins.

  **This lives inside the admin screens.** It is not exposed in regular user
  settings — system admins operate the whole system, and MFA is attached to
  that role.
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
         |> put_flash(:info, "Two-factor authentication turned on.")
         |> load()}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, error: "The code is incorrect. Check the current code in your authenticator app.")}
    end
  end

  def handle_event("disable", %{"code" => code}, socket) do
    case MFA.disable(socket.assigns.current_account, code) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(current_account: updated, error: nil)
         |> put_flash(:info, "Two-factor authentication turned off.")
         |> load()}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, error: "The code is incorrect.")}
    end
  end

  def handle_event("dismiss_codes", _params, socket) do
    {:noreply, assign(socket, backup_codes: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={:security} title="Security" subtitle="Two-factor authentication for system admin accounts">
      <.notice
        :if={@dev_bypass}
        kind={:warn}
        icon="construction"
        title="This is a development environment"
        class="mb-4"
      >
        Here, <strong>any 6-digit number</strong> passes.
        You can try out the setup without an authenticator app.
        This does not work in production — it is fixed at compile time.
      </.notice>

      <.notice :if={@backup_codes} kind={:ok} icon="vpn_key" title="Backup codes" class="mb-4">
        <p>One-time codes for when you lose your authenticator. <strong>You can only see them now.</strong></p>
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
          I have saved them
        </button>
      </.notice>

      <div class="vr-card" data-surface="raised">
        <div class="vr-card__body">
          <div class="flex items-center justify-between gap-4 mb-3">
            <div>
              <h2 class="font-bold" style="color: var(--text-primary);">Two-factor authentication</h2>
              <p class="vr-hint mt-1">
                <span :if={@enabled}>
                  In use since {Calendar.strftime(@enabled_at, "%Y-%m-%d")} · {@codes_left} backup codes left
                </span>
                <span :if={not @enabled}>
                  Protects your account even if your password leaks. Recommended for admins.
                </span>
              </p>
            </div>
            <span class={["vr-chip", if(@enabled, do: "vr-chip--ok", else: "vr-chip--neutral")]}>
              {if @enabled, do: "On", else: "Off"}
            </span>
          </div>

          <p :if={@error} class="vr-notice vr-notice--error mb-3">{@error}</p>

          <%!-- Before setup starts --%>
          <button
            :if={not @enabled and is_nil(@setup)}
            data-surface="control"
            class="vr-btn vr-btn--primary"
            phx-click="start_setup"
          >
            Turn on two-factor authentication
          </button>

          <%!-- During setup --%>
          <div
            :if={@setup}
            class="pt-3"
            style="border-top: var(--hairline-width) solid var(--border-subtle);"
          >
            <ol class="vr-hint" style="line-height:1.9; padding-left:18px; margin-bottom:14px;">
              <li>Open your authenticator app (1Password, Google Authenticator, etc.)</li>
              <li>Register the key below</li>
              <li>Enter the 6-digit code the app shows</li>
            </ol>

            <div class="mb-3">
              <label class="vr-label mb-1.5">Setup key</label>
              <code
                class="vr-key"
                style="display:block; padding:12px; background: var(--surface-inset); border-radius: var(--radius-md); font-size:14px; letter-spacing:.08em; word-break:break-all;"
              >
                {@setup.readable}
              </code>
              <p class="vr-hint mt-1.5" style="font-size:12px;">
                To register via QR code, use this address:
                <span class="vr-key" style="word-break:break-all;">{@setup.uri}</span>
              </p>
            </div>

            <form phx-submit="confirm" class="flex gap-2 items-end">
              <div style="flex:1">
                <label class="vr-label mb-1.5" for="mfa_code">6-digit code</label>
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
              <button type="submit" data-surface="control" class="vr-btn vr-btn--primary">Confirm</button>
              <button
                type="button"
                data-surface="control"
                class="vr-btn vr-btn--ghost"
                phx-click="cancel_setup"
              >
                Cancel
              </button>
            </form>
          </div>

          <%!-- When enabled --%>
          <form
            :if={@enabled}
            phx-submit="disable"
            class="flex gap-2 items-end pt-3"
            style="border-top: var(--hairline-width) solid var(--border-subtle);"
          >
            <div style="flex:1">
              <label class="vr-label mb-1.5" for="disable_code">Enter your current code to turn this off</label>
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
              Turn off
            </button>
          </form>
        </div>
      </div>
    </.shell>
    """
  end
end
