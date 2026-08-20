defmodule VRWeb.API.MeController do
  @moduledoc """
  현재 계정 정보.

  React 앱이 부팅할 때 한 번 받아 테마와 네비게이션을 그린다.

  **`is_admin` 을 내려주지만 그것으로 접근이 열리는 것은 아니다.**
  어드민 경로는 서버가 다시 판정하고, 권한이 없으면 404 를 준다.
  이 값은 링크를 보여줄지 말지에만 쓴다.
  """

  use VRWeb, :controller

  alias VR.Accounts
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  def show(conn, _params) do
    account = conn.assigns.current_account
    json(conn, JSONView.account(account))
  end

  @doc "테마 변경. 설정 화면을 거치지 않고 즉시 저장한다."
  def update_theme(conn, %{"theme" => theme}) do
    account = conn.assigns.current_account

    with {:ok, updated} <- Accounts.update_theme(account, theme) do
      json(conn, JSONView.account(updated))
    end
  end

  @doc """
  지금 이 기기에서 로그아웃한다.

  다른 기기는 그대로 둔다 — 세션 목록에서 따로 끊는다. 비밀번호를 바꿀 때만
  **전부** 끊는다 (`Accounts.update_password/3`).

  SPA 는 폼 POST 를 쓸 수 없어(`DELETE /logout` 은 CSRF 토큰이 필요하다)
  API 로 둔다. 인증 방식은 다른 변경 API 와 같다.
  """
  def logout(conn, _params) do
    if token = get_session(conn, :account_token), do: Accounts.revoke_session(token)

    conn
    |> VRWeb.UserAuth.renew_session()
    |> VRWeb.UserAuth.delete_remember_cookie()
    |> send_resp(:no_content, "")
  end

  @doc """
  기본 전사 언어 변경. 빈 값이면 자동(브라우저 언어)으로 되돌린다.

  녹음할 때마다 고르게 하지 않는다 — 대부분 늘 같은 언어로 회의하고,
  매번 묻는 화면은 녹음을 시작하는 데 한 단계를 더 얹을 뿐이다.
  """
  def update_transcribe_language(conn, params) do
    account = conn.assigns.current_account

    with {:ok, updated} <-
           Accounts.update_transcribe_language(account, params["transcribe_language"]) do
      json(conn, JSONView.account(updated))
    end
  end
end
