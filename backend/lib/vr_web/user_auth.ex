defmodule VRWeb.UserAuth do
  @moduledoc """
  세션 쿠키로 로그인 상태를 관리한다.

  ## 쿠키 정책

  - `http_only` — JS가 읽을 수 없다. XSS로 세션이 새지 않는다
  - `same_site: "Lax"` — 외부 사이트에서 온 POST에 쿠키가 실리지 않는다 (CSRF 완화)
  - `secure` — 운영에서는 HTTPS에서만 전송
  - 서명(signed) — 변조를 감지한다

  쿠키에는 **원본 토큰**이, DB에는 **그 해시**가 들어간다.
  """

  use VRWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias VR.Accounts

  # 파이프라인에서 `plug VRWeb.UserAuth, :fetch_current_account` 형태로 쓴다
  def init(action) when is_atom(action), do: action
  def call(conn, action), do: apply(__MODULE__, action, [conn, []])

  @remember_cookie "_vr_session"
  @max_age 60 * 60 * 24 * 60

  @doc "로그인 처리. 세션을 만들고 쿠키를 심는다."
  def log_in_account(conn, account, params \\ %{}, opts \\ []) do
    {:ok, token, _session} =
      Accounts.create_session(account, %{
        user_agent: get_req_header(conn, "user-agent") |> List.first(),
        ip_address: client_ip(conn),
        mfa_verified_at: opts[:mfa_verified_at]
      })

    # 삭제 예약 상태였다면 로그인으로 취소된다
    if account.scheduled_deletion_at, do: Accounts.cancel_deletion(account)

    Accounts.clear_failures(account.email)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_cookie(token, params)
    |> redirect(to: signed_in_path(conn))
  end

  @doc "로그아웃. 서버 세션을 무효화하고 쿠키를 지운다."
  def log_out_account(conn) do
    if token = get_session(conn, :account_token), do: Accounts.revoke_session(token)

    conn
    |> renew_session()
    |> delete_remember_cookie()
    |> redirect(to: ~p"/login")
  end

  @doc """
  "로그인 상태 유지" 쿠키를 지운다.

  세션만 끊고 이걸 남기면 다음 요청에서 **다시 로그인된다.**
  API 로그아웃(`API.MeController.logout/2`)도 같은 것을 지워야 한다.
  """
  def delete_remember_cookie(conn), do: delete_resp_cookie(conn, @remember_cookie)

  @doc "요청마다 현재 계정을 붙인다."
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

  @doc "로그인해야 지나갈 수 있다."
  def require_authenticated(conn, _opts) do
    if conn.assigns[:current_account] do
      conn
    else
      conn
      |> put_flash(:error, "로그인이 필요합니다")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc """
  API용 인증. 리다이렉트 대신 401 JSON 을 준다.

  API 클라이언트에게 302를 주면 로그인 HTML 을 파싱하려다 이상한 오류가 난다.
  """
  def require_authenticated_api(conn, _opts) do
    if conn.assigns[:current_account] do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        401,
        Jason.encode!(%{status: "error", code: "unauthorized", message: "로그인이 필요합니다"})
      )
      |> halt()
    end
  end

  @doc "이미 로그인했으면 앱으로 보낸다 (로그인·가입 페이지용)."
  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_account] do
      conn |> redirect(to: signed_in_path(conn)) |> halt()
    else
      conn
    end
  end

  @doc "시스템 어드민만."
  def require_admin(conn, _opts) do
    case conn.assigns[:current_account] do
      %{is_admin: true} = account ->
        # 어드민은 2단계 인증이 **의무**다. 아직 안 켰으면 설정부터 시킨다.
        # 어드민 계정 하나가 뚫리면 전체 시스템의 설정과 키가 함께 넘어간다.
        if VR.Accounts.MFA.satisfied?(account) do
          conn
        else
          conn
          |> put_flash(:error, "어드민 계정은 2단계 인증을 켜야 들어갈 수 있습니다.")
          |> redirect(to: ~p"/settings")
          |> halt()
        end

      %{} ->
        # 어드민이 아닌 사람에게는 존재 자체를 숨긴다
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
  LiveView 마운트 훅.

      on_mount {VRWeb.UserAuth, :require_authenticated}
      on_mount {VRWeb.UserAuth, :require_admin}
      on_mount {VRWeb.UserAuth, :mount_current_account}
  """
  def on_mount(:mount_current_account, _params, session, socket) do
    {:cont, assign_current_account(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = assign_current_account(socket, session)

    if socket.assigns.current_account do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "로그인이 필요합니다")
       |> Phoenix.LiveView.redirect(to: ~p"/login")}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = assign_current_account(socket, session)

    case socket.assigns.current_account do
      # 플러그와 같은 규칙 — 어드민이라도 2단계 인증을 켜야 들어간다.
      # LiveView 는 플러그를 거치지 않으므로 여기서도 막아야 한다.
      %{is_admin: true} = account ->
        if VR.Accounts.MFA.satisfied?(account) do
          {:cont, socket}
        else
          {:halt,
           socket
           |> Phoenix.LiveView.put_flash(
             :error,
             "어드민 계정은 2단계 인증을 켜야 들어갈 수 있습니다."
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

  # ── 내부 ─────────────────────────────────────────────────

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

  # 세션 ID를 갈아끼워 세션 고정(fixation) 공격을 막는다
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
