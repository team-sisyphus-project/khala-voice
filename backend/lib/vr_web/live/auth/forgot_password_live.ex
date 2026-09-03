defmodule VRWeb.AuthLive.ForgotPasswordLive do
  @moduledoc """
  Password reset request.

  **Shows the same message whether the account exists or not.** If the response
  differed here, this screen would become a tool for checking whether an email
  address is registered.
  """

  use VRWeb, :live_view

  import VRWeb.AuthLive.Components

  alias VR.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Reset password"))
     |> assign(sent: false)
     |> assign(form: to_form(%{"email" => ""}, as: :account)), layout: false}
  end

  @impl true
  def handle_event("submit", %{"account" => %{"email" => email}}, socket) do
    if account = Accounts.get_account_by_email(email) do
      {:ok, token} = Accounts.create_email_token(account, "reset_password")
      Accounts.Notifier.deliver_reset_password(account, token)
    end

    {:noreply, assign(socket, sent: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_shell
      title={gettext("Reset password")}
      subtitle={if @sent, do: nil, else: gettext("We'll email you a reset link")}
    >
      <div :if={@sent} class="text-center py-2">
        <span
          class="material-symbols-rounded mb-3"
          style="font-size: 40px; color: var(--status-success);"
        >
          mark_email_read
        </span>
        <p style="color: var(--text-primary); font-weight: 600;">{gettext("Email sent")}</p>
        <p class="vr-hint mt-2">
          {gettext("If an account exists for that email, a reset link is on its way.")}<br />
          {gettext("The link expires in 1 hour.")}
        </p>
      </div>

      <.form :if={not @sent} for={@form} phx-submit="submit" class="flex flex-col gap-4">
        <div>
          <label class="vr-label mb-1.5" for="account_email">{gettext("Email")}</label>
          <input
            type="email"
            id="account_email"
            name="account[email]"
            required
            autocomplete="username"
            class="vr-input"
            style="font-family: var(--font-sans);"
          />
        </div>
        <button
          type="submit"
          class="vr-btn vr-btn--primary w-full"
          phx-disable-with={gettext("Sending...")}
        >
          {gettext("Send reset link")}
        </button>
      </.form>

      <:footer>
        <.link navigate={~p"/login"} style="color: var(--accent); font-weight: 600;">
          {gettext("Back to sign in")}
        </.link>
      </:footer>
    </.auth_shell>
    """
  end
end
