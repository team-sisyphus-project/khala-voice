defmodule VRWeb.API.MeController do
  @moduledoc """
  Current account information.

  Fetched once when the React app boots, to render the theme and navigation.

  **`is_admin` is included, but it does not grant access by itself.**
  Admin routes are re-checked by the server, which returns 404 when permission
  is missing. This value is used only to decide whether to show the link.
  """

  use VRWeb, :controller

  alias VR.Accounts
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  def show(conn, _params) do
    account = conn.assigns.current_account
    json(conn, JSONView.account(account))
  end

  @doc "Change the theme. Saved immediately, without going through the settings screen."
  def update_theme(conn, %{"theme" => theme}) do
    account = conn.assigns.current_account

    with {:ok, updated} <- Accounts.update_theme(account, theme) do
      json(conn, JSONView.account(updated))
    end
  end

  @doc """
  Change the UI display language. Saved immediately, without going through the settings screen.

  Separate from the transcription language (`transcribe_language`) — this only changes the UI language.
  """
  def update_locale(conn, %{"locale" => locale}) do
    account = conn.assigns.current_account

    with {:ok, updated} <- Accounts.update_locale(account, locale) do
      json(conn, JSONView.account(updated))
    end
  end

  @doc """
  Sign out of this device only.

  Other devices are left alone — they are disconnected individually from the
  session list. Only a password change disconnects **everything**
  (`Accounts.update_password/3`).

  The SPA cannot use a form POST (`DELETE /logout` requires a CSRF token),
  so this lives in the API. Authentication works the same as the other mutation APIs.
  """
  def logout(conn, _params) do
    if token = get_session(conn, :account_token), do: Accounts.revoke_session(token)

    conn
    |> VRWeb.UserAuth.renew_session()
    |> VRWeb.UserAuth.delete_remember_cookie()
    |> send_resp(:no_content, "")
  end

  @doc """
  Change the default transcription language. An empty value reverts to automatic (browser language).

  We do not ask on every recording — most people always meet in the same language,
  and a prompt each time only adds one more step before recording can start.
  """
  def update_transcribe_language(conn, params) do
    account = conn.assigns.current_account

    with {:ok, updated} <-
           Accounts.update_transcribe_language(account, params["transcribe_language"]) do
      json(conn, JSONView.account(updated))
    end
  end
end
