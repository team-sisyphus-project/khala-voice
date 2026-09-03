defmodule VRWeb.AuthLive.ResetPasswordLive do
  @moduledoc """
  Password reset.

  The token's existence is only checked at mount; it is actually consumed
  exactly once, at submit time.
  """

  use VRWeb, :live_view

  import VRWeb.AuthLive.Components

  alias VR.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Set a new password"))
     |> assign(token: token)
     |> assign(done: false)
     |> assign(form: to_form(%{}, as: :account)), layout: false}
  end

  @impl true
  def handle_event("submit", %{"account" => params}, socket) do
    case Accounts.reset_password(socket.assigns.token, params) do
      {:ok, _account} ->
        {:noreply, assign(socket, done: true)}

      :error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This link has expired or was already used. Please request a new one.")
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :account))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_shell title={gettext("Set a new password")}>
      <div :if={@done} class="text-center py-2">
        <span
          class="material-symbols-rounded mb-3"
          style="font-size: 40px; color: var(--status-success);"
        >
          check_circle
        </span>
        <p style="color: var(--text-primary); font-weight: 600;">
          {gettext("Your password has been changed")}
        </p>
        <p class="vr-hint mt-2">
          {gettext("For your security, you've been signed out on all other devices.")}
        </p>
        <.link navigate={~p"/login"} class="vr-btn vr-btn--primary w-full mt-5">
          {gettext("Sign in")}
        </.link>
      </div>

      <.form :let={f} :if={not @done} for={@form} phx-submit="submit" class="flex flex-col gap-4">
        <div>
          <label class="vr-label mb-1.5" for="account_password">{gettext("New password")}</label>
          <input
            type="password"
            id="account_password"
            name="account[password]"
            required
            autocomplete="new-password"
            class="vr-input"
            style="font-family: var(--font-sans);"
          />
          <p class="vr-hint mt-1.5" style="font-size: 12px;">{gettext("At least 10 characters")}</p>
          <.field_errors field={f[:password]} />
        </div>

        <div>
          <label class="vr-label mb-1.5" for="account_password_confirmation">
            {gettext("Confirm password")}
          </label>
          <input
            type="password"
            id="account_password_confirmation"
            name="account[password_confirmation]"
            required
            autocomplete="new-password"
            class="vr-input"
            style="font-family: var(--font-sans);"
          />
          <.field_errors field={f[:password_confirmation]} />
        </div>

        <button
          type="submit"
          class="vr-btn vr-btn--primary w-full"
          phx-disable-with={gettext("Changing...")}
        >
          {gettext("Change password")}
        </button>
      </.form>
    </.auth_shell>
    """
  end
end
