defmodule VRWeb.LocaleIntegrationTest do
  @moduledoc """
  계정 `locale` 이 실제 렌더까지 흐르는지 확인한다.

  - 컨트롤러 경로: `:browser` 파이프라인의 `VRWeb.Plugs.Locale`.
  - LiveView 경로: `VRWeb.UserAuth.on_mount(:set_locale, ...)`.

  두 경로 모두 루트 레이아웃의 `<html lang>` 로 관측한다.
  """
  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts

  defp log_in(conn, account) do
    {:ok, token, _} = Accounts.create_session(account)
    Plug.Test.init_test_session(conn, %{account_token: token})
  end

  describe "LiveView 렌더 (on_mount :set_locale)" do
    test "en 계정은 <html lang=en> 로 렌더된다", %{conn: conn} do
      account = account_fixture(%{locale: "en"})
      conn = conn |> log_in(account) |> get(~p"/settings")

      assert html_response(conn, 200) =~ ~s(<html lang="en")
    end

    test "ko 계정은 <html lang=ko> 로 렌더된다", %{conn: conn} do
      account = account_fixture(%{locale: "ko"})
      conn = conn |> log_in(account) |> get(~p"/settings")

      assert html_response(conn, 200) =~ ~s(<html lang="ko")
    end
  end

  describe "LiveView 렌더 — 폴백" do
    test "미로그인 페이지는 영어로 폴백한다", %{conn: conn} do
      conn = get(conn, ~p"/login")

      assert html_response(conn, 200) =~ ~s(<html lang="en")
    end
  end

  describe "컨트롤러 파이프라인 (Plugs.Locale)" do
    # React SPA 진입 페이지는 정적 index.html 을 그대로 보내 루트 레이아웃을 거치지
    # 않는다. 그래서 컨트롤러 경로는 `<html lang>` 이 아니라 플러그가 심는 세션
    # `:locale`(요청 프로세스 Gettext 로케일과 짝) 로 관측한다.
    test "브라우저 요청은 계정 locale 을 세션에 심는다", %{conn: conn} do
      account = account_fixture(%{locale: "ko"})
      conn = conn |> log_in(account) |> get(~p"/")

      assert get_session(conn, :locale) == "ko"
    end

    test "미로그인 브라우저 요청은 영어를 세션에 심는다", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert get_session(conn, :locale) == "en"
    end
  end
end
