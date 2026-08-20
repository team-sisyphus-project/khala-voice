defmodule VRWeb.SessionController do
  @moduledoc """
  로그인·로그아웃의 실제 처리.

  LiveView는 WebSocket 위에서 돌아 쿠키를 심을 수 없다.
  그래서 폼은 LiveView가 그리고 제출은 여기로 온다.
  """

  use VRWeb, :controller

  alias VR.Accounts
  alias VR.Accounts.MFA
  alias VRWeb.UserAuth

  @doc "가입 직후 자동 로그인."
  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "가입이 완료되었습니다. 확인 메일을 보냈습니다.")
  end

  def create(conn, params), do: create(conn, params, nil)

  defp create(conn, %{"account" => account_params}, info) do
    %{"email" => email, "password" => password} = account_params
    ip = client_ip(conn)

    case Accounts.login_allowed?(email, ip) do
      {:error, :too_many_attempts} ->
        conn
        |> put_flash(:error, "로그인 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.")
        |> redirect(to: ~p"/login")

      :ok ->
        case Accounts.get_account_by_email_and_password(email, password) do
          nil ->
            Accounts.record_login_attempt(email, ip, false)

            # 계정이 없는 것인지 비밀번호가 틀린 것인지 구분해 알려주지 않는다
            conn
            |> put_flash(:error, "이메일 또는 비밀번호가 올바르지 않습니다")
            |> redirect(to: ~p"/login")

          account ->
            Accounts.record_login_attempt(email, ip, true)

            if MFA.required?(account) do
              # 아직 로그인시키지 않는다. 코드 확인까지 통과해야 세션이 생긴다.
              # 여기 담는 것은 계정 ID 뿐이고, 세션 토큰은 그 뒤에 발급된다.
              #
              # **아직 켜지 않았으면 등록부터.** 코드 화면으로 보내면 확인할 코드가
              # 없어 아무 데도 못 간다 — 켜는 화면이 어드민 구역 안에 있으면
              # 그게 데드락이 된다 (devkanban 이 `/login/mfa/enroll` 로 푼 문제).
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
  2단계 인증 확인. 통과하면 그때 세션이 생긴다.

  대기 상태는 5분만 유효하다 — 로그인 화면을 열어둔 채 자리를 비운 사이
  누군가 코드만 넣으면 들어가는 상황을 막는다.
  """
  def verify_mfa(conn, %{"code" => code}) do
    account_id = get_session(conn, :mfa_pending_account_id)
    started_at = get_session(conn, :mfa_pending_at)
    remember? = get_session(conn, :mfa_remember_me)

    cond do
      is_nil(account_id) or expired?(started_at) ->
        conn
        |> clear_mfa_pending()
        |> put_flash(:error, "인증 시간이 지났습니다. 다시 로그인해 주세요.")
        |> redirect(to: ~p"/login")

      true ->
        account = Accounts.get_account(account_id)

        case account && MFA.verify(account, code) do
          :ok ->
            conn
            |> clear_mfa_pending()
            |> UserAuth.log_in_account(account, %{
              "remember_me" => if(remember?, do: "true", else: "false")
            })

          _ ->
            Accounts.record_login_attempt(account && account.email, client_ip(conn), false)

            conn
            |> put_flash(:error, "코드가 맞지 않습니다")
            |> redirect(to: ~p"/login/mfa")
        end
    end
  end

  @doc """
  2단계 인증을 켜고 로그인을 마친다 (`POST /login/mfa/enroll`).

  **출처: devkanban** `SessionController.verify_enroll/2` — 같은 흐름이다.
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
        |> put_flash(:error, "인증 시간이 지났습니다. 다시 로그인해 주세요.")
        |> redirect(to: ~p"/login")

      true ->
        account = Accounts.get_account(account_id)
        secret = decode_secret(params["secret"])

        with %{} <- account,
             {:ok, binary} <- secret,
             {:ok, updated, backup_codes} <- MFA.enable(account, binary, params["code"] || "") do
          conn
          |> clear_mfa_pending()
          # 백업 코드는 **지금만** 보여줄 수 있다. 해시로만 저장하기 때문이다.
          |> put_session(:mfa_backup_codes, backup_codes)
          |> put_flash(:info, "2단계 인증을 켰습니다. 백업 코드를 설정에서 확인하세요.")
          |> UserAuth.log_in_account(updated, %{
            "remember_me" => if(remember?, do: "true", else: "false")
          })
        else
          _ ->
            conn
            |> put_flash(:error, "코드가 맞지 않습니다")
            |> redirect(to: ~p"/login/mfa/enroll")
        end
    end
  end

  # 등록 폼은 비밀키를 base32 로 실어 보낸다 (인증기 앱이 쓰는 표기와 같다).
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
    |> put_flash(:info, "로그아웃되었습니다")
    |> UserAuth.log_out_account()
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
