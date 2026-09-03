defmodule VRWeb.AuthLive.ScreensI18nTest do
  @moduledoc """
  로그인/가입 흐름의 auth 화면이 번역되는지 확인한다.

  auth 화면은 세션 성립 전 단계라 `current_account` 가 없다 — 로케일은 항상
  기본값(en)으로 해석된다(로그인한 사용자는 `:redirect_if_authenticated` 로
  이 화면들에 도달하지 못한다). 따라서:

  - 화면 렌더 검사: 익명 방문이 en 으로 렌더되고 하드코딩 한국어가 남지 않는지.
  - ko 회귀 검사: ko 카탈로그가 auth 문안을 실제로 번역하는지(카탈로그 직접 조회).
  """
  use VRWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import VR.AccountsFixtures

  # 한글 음절 블록. `u` 플래그로 유니코드 코드포인트를 매칭한다(em-dash 등
  # 멀티바이트 문자를 바이트 범위로 오매칭하지 않도록).
  @hangul ~r/[가-힣]/u

  describe "로그인 화면" do
    test "익명 방문은 영어로 렌더되고 한국어가 남지 않는다", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/login")
      html = render(lv)

      assert html =~ "Sign in"
      assert html =~ "Record your meetings and organize them automatically"
      assert html =~ "Keep me signed in"
      assert html =~ "Forgot your password?"
      refute html =~ @hangul
    end
  end

  describe "가입 화면" do
    test "익명 방문은 영어로 렌더되고 한국어가 남지 않는다", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/register")
      html = render(lv)

      assert html =~ "Sign up"
      assert html =~ "At least 10 characters"
      assert html =~ "Already have an account?"
      refute html =~ @hangul
    end
  end

  describe "비밀번호 재설정 요청 화면" do
    test "익명 방문은 영어로 렌더되고 한국어가 남지 않는다", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/forgot-password")
      html = render(lv)

      assert html =~ "Reset password"
      assert html =~ "email you a reset link"
      assert html =~ "Send reset link"
      refute html =~ @hangul
    end
  end

  describe "새 비밀번호 설정 화면" do
    test "익명 방문은 영어로 렌더되고 한국어가 남지 않는다", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/reset-password/any-token")
      html = render(lv)

      assert html =~ "Set a new password"
      assert html =~ "New password"
      assert html =~ "Confirm password"
      refute html =~ @hangul
    end
  end

  describe "MFA 인증 코드 화면" do
    test "en 폴백으로 렌더되고 한국어가 남지 않는다", %{conn: conn} do
      account = confirmed_account_fixture(%{name: "Ada"})
      conn = Plug.Test.init_test_session(conn, %{"mfa_pending_account_id" => account.id})

      {:ok, lv, _} = live(conn, ~p"/login/mfa")
      html = render(lv)

      assert html =~ "Verification code"
      assert html =~ "Enter the 6-digit code from your authenticator app"
      refute html =~ @hangul
    end
  end

  describe "MFA 등록 화면" do
    test "en 폴백으로 렌더되고 한국어가 남지 않는다", %{conn: conn} do
      account = confirmed_account_fixture(%{name: "Ada"})
      conn = Plug.Test.init_test_session(conn, %{"mfa_pending_account_id" => account.id})

      {:ok, lv, _} = live(conn, ~p"/login/mfa/enroll")
      html = render(lv)

      assert html =~ "Set up two-factor authentication"
      assert html =~ "Add the key below"
      assert html =~ "Turn on and continue"
      refute html =~ @hangul
    end
  end

  describe "ko 카탈로그 회귀" do
    setup do
      Gettext.put_locale(VRWeb.Gettext, "ko")
      on_exit(fn -> Gettext.put_locale(VRWeb.Gettext, "en") end)
    end

    test "auth 문안이 ko 로 번역된다" do
      assert Gettext.gettext(VRWeb.Gettext, "Sign in") == "로그인"
      assert Gettext.gettext(VRWeb.Gettext, "Sign up") == "가입하기"
      assert Gettext.gettext(VRWeb.Gettext, "Keep me signed in") == "로그인 상태 유지"
      assert Gettext.gettext(VRWeb.Gettext, "Reset password") == "비밀번호 재설정"
      assert Gettext.gettext(VRWeb.Gettext, "Set a new password") == "새 비밀번호 설정"
      assert Gettext.gettext(VRWeb.Gettext, "Verification code") == "인증 코드"

      assert Gettext.gettext(VRWeb.Gettext, "Set up two-factor authentication") ==
               "2단계 인증 설정"

      assert Gettext.gettext(VRWeb.Gettext, "Turn on and continue") == "켜고 계속"
    end

    test "OAuth 제공자 보간 문안이 ko 로 번역된다" do
      assert Gettext.gettext(VRWeb.Gettext, "Continue with %{provider}", provider: "Google") ==
               "Google로 계속하기"
    end
  end
end
