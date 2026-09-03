defmodule VRWeb.SessionController do
  @moduledoc """
  The actual sign-in / sign-out handling.

  LiveView runs over a WebSocket and cannot set cookies.
  So LiveView renders the form, and submissions come here.
  """

  use VRWeb, :controller

  alias VR.Accounts
  alias VR.Accounts.MFA
  alias VRWeb.UserAuth

  @doc "Automatic sign-in right after registration."
  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Registration complete. A confirmation email has been sent.")
  end

  def create(conn, params), do: create(conn, params, nil)

  defp create(conn, %{"account" => account_params}, info) do
    %{"email" => email, "password" => password} = account_params
    ip = client_ip(conn)

    case Accounts.login_allowed?(email, ip) do
      {:error, :too_many_attempts} ->
        conn
        |> put_flash(:error, "Too many sign-in attempts. Please try again later.")
        |> redirect(to: ~p"/login")

      :ok ->
        case Accounts.get_account_by_email_and_password(email, password) do
          nil ->
            Accounts.record_login_attempt(email, ip, false)

            # Don't reveal whether the account is missing or the password is wrong
            conn
            |> put_flash(:error, "Invalid email or password")
            |> redirect(to: ~p"/login")

          account ->
            Accounts.record_login_attempt(email, ip, true)

            if MFA.required?(account) do
              # Don't sign them in yet. The session is only created once the code
              # check passes. All we store here is the account ID; the session
              # token is issued afterwards.
              #
              # **If MFA is not enabled yet, enroll first.** Sending them to the
              # code screen would leave them stuck with no code to verify — and if
              # the enable screen lives inside the admin area, that becomes a
              # deadlock (the problem devkanban solved with `/login/mfa/enroll`).
              target = if account.mfa_enabled, do: ~p"/login/mfa", else: ~p"/login/mfa/enroll"

              conn
              |> put_session(:mfa_pending_account_id, account.id)
              |> put_session(:mfa_pending_at, System.system_time(:second))
              |> put_session(:mfa_remember_me, account_params["remember_me"] == "true")
              |> redirect(to: target)
            else
              conn
              |> then(&if info, do: put_flash(&1, :info, info), else: &1)
              |> UserAuth.log_in_account(account, account_params)
            end
        end
    end
  end

  @doc """
  Two-factor authentication check. The session is created only on success.

  The pending state is valid for just 5 minutes — this prevents someone from
  getting in by simply entering a code while the user is away from an open
  sign-in screen.
  """
  def verify_mfa(conn, %{"code" => code}) do
    account_id = get_session(conn, :mfa_pending_account_id)
    started_at = get_session(conn, :mfa_pending_at)
    remember? = get_session(conn, :mfa_remember_me)

    cond do
      is_nil(account_id) or expired?(started_at) ->
        conn
        |> clear_mfa_pending()
        |> put_flash(:error, "Verification timed out. Please sign in again.")
        |> redirect(to: ~p"/login")

      true ->
        account = Accounts.get_account(account_id)

        case account && MFA.verify(account, code) do
          :ok ->
            conn
            |> clear_mfa_pending()
            |> UserAuth.log_in_account(
              account,
              %{"remember_me" => if(remember?, do: "true", else: "false")},
              mfa_verified_at: DateTime.utc_now(:second)
            )

          _ ->
            Accounts.record_login_attempt(account && account.email, client_ip(conn), false)

            conn
            |> put_flash(:error, "The code is incorrect")
            |> redirect(to: ~p"/login/mfa")
        end
    end
  end

  @doc """
  Enables two-factor authentication and completes sign-in (`POST /login/mfa/enroll`).

  **Source: devkanban** `SessionController.verify_enroll/2` — the same flow.
  """
  def enroll(conn, params) do
    account_id = get_session(conn, :mfa_pending_account_id)
    started_at = get_session(conn, :mfa_pending_at)
    remember? = get_session(conn, :mfa_remember_me) == true

    cond do
      is_nil(account_id) ->
        redirect(conn, to: ~p"/login")

      expired?(started_at) ->
        conn
        |> clear_mfa_pending()
        |> put_flash(:error, "Verification timed out. Please sign in again.")
        |> redirect(to: ~p"/login")

      true ->
        account = Accounts.get_account(account_id)
        secret = decode_secret(params["secret"])

        with %{} <- account,
             {:ok, binary} <- secret,
             {:ok, updated, backup_codes} <- MFA.enable(account, binary, params["code"] || "") do
          conn
          |> clear_mfa_pending()
          # Backup codes can only be shown **right now** — we store only their hashes.
          |> put_session(:mfa_backup_codes, backup_codes)
          |> put_flash(:info, "Two-factor authentication is enabled. Check your backup codes in Settings.")
          |> UserAuth.log_in_account(
            updated,
            %{"remember_me" => if(remember?, do: "true", else: "false")},
            mfa_verified_at: DateTime.utc_now(:second)
          )
        else
          _ ->
            conn
            |> put_flash(:error, "The code is incorrect")
            |> redirect(to: ~p"/login/mfa/enroll")
        end
    end
  end

  # The enrollment form carries the secret in base32 (the same notation authenticator apps use).
  defp decode_secret(value) when is_binary(value) and value != "",
    do: Base.decode32(value, padding: false)

  defp decode_secret(_), do: :error

  @mfa_window_seconds 300

  defp expired?(nil), do: true

  defp expired?(started_at),
    do: System.system_time(:second) - started_at > @mfa_window_seconds

  defp clear_mfa_pending(conn) do
    conn
    |> delete_session(:mfa_pending_account_id)
    |> delete_session(:mfa_pending_at)
    |> delete_session(:mfa_remember_me)
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "You have been signed out")
    |> UserAuth.log_out_account()
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
