defmodule VRWeb.UserAuth do
  @moduledoc """
  Manages sign-in state via a session cookie.

  ## Cookie policy

  - `http_only` — unreadable from JS, so XSS cannot leak the session
  - `same_site: "Lax"` — the cookie is not sent on POSTs from external sites (CSRF mitigation)
  - `secure` — sent only over HTTPS in production
  - signed — tampering is detected

  The cookie holds the **original token**; the DB holds **its hash**.
  """

  use VRWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  use Gettext, backend: VRWeb.Gettext

  alias VR.Accounts

  # Used in pipelines as `plug VRWeb.UserAuth, :fetch_current_account`
  def init(action) when is_atom(action), do: action
  def call(conn, action), do: apply(__MODULE__, action, [conn, []])

  @remember_cookie "_vr_session"
  @max_age 60 * 60 * 24 * 60

  @doc "Handles sign-in. Creates a session and sets the cookie."
  def log_in_account(conn, account, params \\ %{}, opts \\ []) do
    {:ok, token, _session} =
      Accounts.create_session(account, %{
        user_agent: get_req_header(conn, "user-agent") |> List.first(),
        ip_address: client_ip(conn),
        mfa_verified_at: opts[:mfa_verified_at]
      })

    # If the account was scheduled for deletion, signing in cancels it
    if account.scheduled_deletion_at, do: Accounts.cancel_deletion(account)

    Accounts.clear_failures(account.email)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_cookie(token, params)
    |> redirect(to: signed_in_path(conn))
  end

  @doc "Signs out. Invalidates the server session and clears the cookie."
  def log_out_account(conn) do
    if token = get_session(conn, :account_token), do: Accounts.revoke_session(token)

    conn
    |> renew_session()
    |> delete_remember_cookie()
    |> redirect(to: ~p"/login")
  end

  @doc """
  Clears the "remember me" cookie.

  Cutting only the session and leaving this behind means the next request
  **signs the user back in.** The API logout (`API.MeController.logout/2`)
  must clear the same cookie.
  """
  def delete_remember_cookie(conn), do: delete_resp_cookie(conn, @remember_cookie)

  @doc "Attaches the current account on every request."
  def fetch_current_account(conn, _opts) do
    {token, conn} = ensure_token(conn)

    case token && Accounts.get_account_by_session_token(token) do
      {:ok, account, session} ->
        conn
        |> assign(:current_account, account)
        |> assign(:current_session, session)

      _ ->
        conn
        |> assign(:current_account, nil)
        |> assign(:current_session, nil)
    end
  end

  @doc "Requires sign-in to pass."
  def require_authenticated(conn, _opts) do
    if conn.assigns[:current_account] do
      conn
    else
      conn
      |> put_flash(:error, gettext("You must sign in to continue"))
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc """
  Authentication for the API. Responds with 401 JSON instead of a redirect.

  Giving an API client a 302 leads to confusing errors as it tries to parse
  the sign-in HTML.
  """
  def require_authenticated_api(conn, _opts) do
    if conn.assigns[:current_account] do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        401,
        Jason.encode!(%{status: "error", code: "unauthorized", message: "Sign in required"})
      )
      |> halt()
    end
  end

  @doc "Sends already signed-in users to the app (for the sign-in and sign-up pages)."
  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_account] do
      conn |> redirect(to: signed_in_path(conn)) |> halt()
    else
      conn
    end
  end

  @doc "System admins only."
  def require_admin(conn, _opts) do
    case conn.assigns[:current_account] do
      %{is_admin: true} = account ->
        # Two-factor authentication is **mandatory** for admins. If it is not
        # enabled yet, send them to settings first. One breached admin account
        # takes the whole system's settings and keys with it.
        if VR.Accounts.MFA.satisfied?(account) do
          conn
        else
          conn
          |> put_flash(:error, "Admin accounts must enable two-factor authentication to enter.")
          |> redirect(to: ~p"/settings")
          |> halt()
        end

      %{} ->
        # Hide even the existence of this area from non-admins
        conn |> send_resp(404, "Not Found") |> halt()

      _ ->
        conn
        |> maybe_store_return_to()
        |> redirect(to: ~p"/login")
        |> halt()
    end
  end

  # ── LiveView ─────────────────────────────────────────────

  @doc """
  LiveView mount hooks.

      on_mount {VRWeb.UserAuth, :require_authenticated}
      on_mount {VRWeb.UserAuth, :require_admin}
      on_mount {VRWeb.UserAuth, :mount_current_account}
      on_mount {VRWeb.UserAuth, :set_locale}
  """
  def on_mount(:mount_current_account, _params, session, socket) do
    {:cont, assign_current_account(socket, session)}
  end

  # Sets this LiveView process's Gettext locale from the current account's
  # `locale`. The LiveView counterpart of `VRWeb.Plugs.Locale` — controllers
  # get the rule from the plug, LiveViews from this hook (account `locale`,
  # falling back to English). Place it **after** the hooks that read the
  # account (`:mount_current_account` and `:require_authenticated`).
  def on_mount(:set_locale, _params, _session, socket) do
    locale = VRWeb.Plugs.Locale.resolve(socket.assigns[:current_account])
    Gettext.put_locale(VRWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = assign_current_account(socket, session)

    if socket.assigns.current_account do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, gettext("You must sign in to continue"))
       |> Phoenix.LiveView.redirect(to: ~p"/login")}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = assign_current_account(socket, session)

    case socket.assigns.current_account do
      # Same rule as the plug — even admins must enable two-factor
      # authentication to enter. LiveView does not go through plugs, so we
      # have to block here as well.
      %{is_admin: true} = account ->
        if VR.Accounts.MFA.satisfied?(account) do
          {:cont, socket}
        else
          {:halt,
           socket
           |> Phoenix.LiveView.put_flash(
             :error,
             "Admin accounts must enable two-factor authentication to enter."
           )
           |> Phoenix.LiveView.redirect(to: ~p"/settings")}
        end

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp assign_current_account(socket, session) do
    socket
    |> Phoenix.Component.assign_new(:current_account, fn ->
      with token when is_binary(token) <- session["account_token"],
           {:ok, account, _} <- Accounts.get_account_by_session_token(token) do
        account
      else
        _ -> nil
      end
    end)
    |> Phoenix.Component.assign_new(:current_session, fn ->
      with token when is_binary(token) <- session["account_token"],
           {:ok, _, current_session} <- Accounts.get_account_by_session_token(token) do
        current_session
      else
        _ -> nil
      end
    end)
  end

  # ── Internal ─────────────────────────────────────────────

  defp ensure_token(conn) do
    if token = get_session(conn, :account_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_cookie])

      case conn.cookies[@remember_cookie] do
        token when is_binary(token) -> {token, put_token_in_session(conn, token)}
        _ -> {nil, conn}
      end
    end
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:account_token, token)
    |> put_session(:live_socket_id, "accounts_sessions:#{Base.url_encode64(token)}")
  end

  defp maybe_write_remember_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_cookie, token,
      sign: true,
      max_age: @max_age,
      same_site: "Lax",
      http_only: true,
      secure: secure?()
    )
  end

  defp maybe_write_remember_cookie(conn, _token, _params), do: conn

  # Swaps out the session ID to prevent session fixation attacks
  @doc false
  def renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp signed_in_path(conn) do
    get_session(conn, :return_to) || "/go/meetings"
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp secure?, do: Application.get_env(:vr, :https_only, false)
end
