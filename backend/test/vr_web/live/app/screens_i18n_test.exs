defmodule VRWeb.AppLive.ScreensI18nTest do
  @moduledoc """
  로그인 후 앱 화면(친구·설정·초대)이 계정 `locale` 에 따라 번역되는지 확인한다.

  - `en` 계정: 화면에 하드코딩 한국어가 남지 않는다.
  - `ko` 계정: 기존 한국어 문안이 그대로 보인다.

  UI 언어 선택기의 원어명(`한국어`·`日本語` …)은 번역 대상이 아니므로(각 언어의
  엔도님), 설정 화면의 한국어 검사는 원어명이 아닌 **UI 문안**으로 좁혀 확인한다.
  """
  use VRWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import VR.AccountsFixtures

  alias VR.Accounts
  alias VR.Friends

  # 한글 음절 블록. 화면에 한국어가 렌더되는지 판별한다.
  # 루트 레이아웃(`root.html.heex`)의 JS 주석은 이 grain 범위 밖이므로,
  # LiveView 자체의 렌더 본문(`render/1`)만 대상으로 검사한다.
  @hangul ~r/[가-힣]/

  defp log_in(conn, account) do
    {:ok, token, _} = Accounts.create_session(account)
    Plug.Test.init_test_session(conn, %{account_token: token})
  end

  describe "친구 화면" do
    test "en 계정은 영어로 렌더되고 한국어가 남지 않는다", %{conn: conn} do
      account = confirmed_account_fixture(%{locale: "en", name: "Ada"})
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/friends")
      html = render(lv)

      assert html =~ "Invite"
      assert html =~ "Share meeting notes with friends"
      assert html =~ "No friends yet"
      refute html =~ @hangul
    end

    test "ko 계정은 한국어로 렌더된다", %{conn: conn} do
      account = confirmed_account_fixture(%{locale: "ko", name: "Ada"})
      {:ok, _lv, html} = conn |> log_in(account) |> live(~p"/friends")

      assert html =~ "초대하기"
      assert html =~ "아직 친구가 없습니다"
    end
  end

  describe "설정 화면" do
    # 언어 선택기의 원어명(`한국어` 등)은 항상 렌더되므로 한글 전체 검사 대신
    # UI 문안 한국어가 사라졌는지로 확인한다.
    test "en 계정은 영어 UI 문안으로 렌더된다", %{conn: conn} do
      account = confirmed_account_fixture(%{locale: "en", name: "Ada"})
      {:ok, _lv, html} = conn |> log_in(account) |> live(~p"/settings")

      assert html =~ "Account settings"
      assert html =~ "Profile"
      assert html =~ "Signed-in devices"
      assert html =~ "Delete account"

      refute html =~ "프로필"
      refute html =~ "비밀번호"
      refute html =~ "로그인된 기기"
      refute html =~ "계정 삭제"
    end

    test "ko 계정은 한국어 UI 문안으로 렌더된다", %{conn: conn} do
      account = confirmed_account_fixture(%{locale: "ko", name: "Ada"})
      {:ok, _lv, html} = conn |> log_in(account) |> live(~p"/settings")

      assert html =~ "프로필"
      assert html =~ "로그인된 기기"
      assert html =~ "계정 삭제"
    end
  end

  describe "초대 화면 (미로그인)" do
    defp invitation_token(locale) do
      inviter = confirmed_account_fixture(%{name: "Grace"})
      {:ok, _invitation, token} = Friends.create_invitation(inviter, %{email: ""})
      {token, locale}
    end

    test "요청 계정이 en 이면 영어로 렌더되고 한국어가 남지 않는다", %{conn: conn} do
      # 미로그인 초대 화면은 폴백(en)으로 렌더된다.
      {token, _} = invitation_token("en")
      {:ok, lv, _} = live(conn, ~p"/invite/#{token}")
      html = render(lv)

      assert html =~ "Friend invitation"
      assert html =~ "invited you as a friend."
      assert html =~ "Sign in"
      assert html =~ "Sign up"
      refute html =~ @hangul
    end

    test "ko 계정으로 열면 한국어로 렌더된다", %{conn: conn} do
      account = confirmed_account_fixture(%{locale: "ko", name: "Ada"})
      {token, _} = invitation_token("ko")
      {:ok, _lv, html} = conn |> log_in(account) |> live(~p"/invite/#{token}")

      assert html =~ "친구 초대"
      assert html =~ "님이 친구로 초대했습니다."
    end
  end
end
