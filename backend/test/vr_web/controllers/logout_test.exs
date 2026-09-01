defmodule VRWeb.LogoutTest do
  @moduledoc """
  로그아웃.

  **세션만 끊고 "로그인 상태 유지" 쿠키를 남기면 다음 요청에서 다시 로그인된다.**
  둘 다 끊는지 확인한다.
  """

  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts

  setup %{conn: conn} do
    account = account_fixture()

    conn =
      post(conn, ~p"/login", %{
        "account" => %{
          "email" => account.email,
          "password" => valid_password(),
          "remember_me" => "true"
        }
      })

    %{conn: conn, account: account}
  end

  defp session_count(account) do
    account.id |> Accounts.list_sessions() |> length()
  end

  describe "API 로그아웃 (앱)" do
    test "세션을 끊고 쿠키를 지운다", %{conn: conn, account: account} do
      assert session_count(account) == 1

      conn = conn |> recycle_session() |> delete(~p"/api/me/session")
      assert conn.status == 204

      assert session_count(account) == 0

      # 쿠키를 지우지 않으면 다음 요청에서 되살아난다
      assert conn.resp_cookies["_vr_session"][:max_age] == 0
    end

    test "로그아웃한 뒤에는 API 가 막힌다", %{conn: conn} do
      conn = conn |> recycle_session() |> delete(~p"/api/me/session")

      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(Plug.Conn.get_session(conn))
        |> get(~p"/api/me")

      assert conn.status == 401
    end
  end

  describe "폼 로그아웃 (LiveView 화면)" do
    test "로그인 화면으로 보낸다", %{conn: conn, account: account} do
      conn = conn |> recycle_session() |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      assert session_count(account) == 0
    end
  end

  defp recycle_session(conn) do
    conn
    |> recycle()
    |> Plug.Test.init_test_session(Plug.Conn.get_session(conn))
  end
end
