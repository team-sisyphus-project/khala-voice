defmodule VRWeb.I18nSweepTest do
  @moduledoc """
  전 화면 잔존 한국어 회귀 그물망 (LiveView).

  개별 화면 테스트(`app/screens_i18n_test.exs`·`auth/screens_i18n_test.exs`)가
  화면별 문안을 확인하는 반면, 이 스위트는 **로그인 후 앱 LiveView 전체**를
  한 곳에서 훑어 `en` 렌더에 하드코딩 한국어가 새지 않는지, `ko` 렌더가 실제로
  한국어로 나오는지(영어 폴백이 아닌지)를 회귀로 잡는다. React 쪽 i18n 테스트
  (`apps/web/src/i18n/*.test.ts`)의 서버 짝이다.

  검사 대상은 **렌더된 마크업**이다. UI 언어 선택기의 원어명(`한국어`)은
  번역 대상이 아닌 엔도님이라(voice/base 엔도님 규칙) 검사 전에 제거한다.
  """
  use VRWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import VR.AccountsFixtures

  alias VR.Accounts
  alias VR.Friends

  # 한글 음절 블록. `u` 플래그로 코드포인트 단위 매칭(멀티바이트 문자를 바이트
  # 범위로 오매칭하지 않는다 — em-dash 등).
  @hangul ~r/[가-힣]/u

  # 설정 화면 UI 언어 선택기의 엔도님(원어명)은 번역 대상이 아니다.
  @endonyms ["한국어"]

  defp log_in(conn, account) do
    {:ok, token, _} = Accounts.create_session(account)
    Plug.Test.init_test_session(conn, %{account_token: token})
  end

  defp strip_endonyms(html), do: Enum.reduce(@endonyms, html, &String.replace(&2, &1, ""))

  defp invite_token do
    inviter = confirmed_account_fixture(%{name: "Grace"})
    {:ok, _invitation, token} = Friends.create_invitation(inviter, %{email: ""})
    token
  end

  describe "en 계정: 앱 LiveView 전 화면에 잔존 한국어가 없다" do
    setup do
      %{account: confirmed_account_fixture(%{locale: "en", name: "Ada"})}
    end

    test "친구 화면", %{conn: conn, account: account} do
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/friends")
      refute strip_endonyms(render(lv)) =~ @hangul
    end

    test "설정 화면 (엔도님 제외)", %{conn: conn, account: account} do
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/settings")
      refute strip_endonyms(render(lv)) =~ @hangul
    end

    test "초대 화면 (미로그인 폴백 en)", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/invite/#{invite_token()}")
      refute strip_endonyms(render(lv)) =~ @hangul
    end
  end

  describe "ko 계정: 앱 LiveView 전 화면이 한국어로 렌더된다 (영어 폴백 아님)" do
    setup do
      %{account: confirmed_account_fixture(%{locale: "ko", name: "Ada"})}
    end

    test "친구 화면", %{conn: conn, account: account} do
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/friends")
      assert render(lv) =~ @hangul
    end

    test "설정 화면", %{conn: conn, account: account} do
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/settings")
      assert render(lv) =~ @hangul
    end

    test "초대 화면", %{conn: conn, account: account} do
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/invite/#{invite_token()}")
      assert render(lv) =~ @hangul
    end
  end

  describe "미로그인 접근 차단 플래시" do
    # `UserAuth.require_authenticated`(컨트롤러 플러그)와 `on_mount(:require_authenticated)`
    # (LiveView)가 같은 msgid 를 쓴다. 미로그인 사용자는 항상 en(계정 없음 → 폴백)이라
    # 플래시가 영어로 나와야 한다 — 종전에는 하드코딩 한국어가 로그인 화면에 남았다.
    test "en(기본): 플러그 플래시가 영어이고 한국어가 없다", %{conn: conn} do
      Gettext.put_locale(VRWeb.Gettext, "en")

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> VRWeb.UserAuth.require_authenticated([])

      flash = Phoenix.Flash.get(conn.assigns.flash, :error)
      assert flash == "You must sign in to continue"
      refute flash =~ @hangul
    end

    test "LiveView 마운트: 미로그인은 로그인으로 리다이렉트된다", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/friends")
    end

    test "ko 카탈로그: 번역이 존재한다", %{conn: _conn} do
      Gettext.put_locale(VRWeb.Gettext, "en")

      assert Gettext.gettext(VRWeb.Gettext, "You must sign in to continue") ==
               "You must sign in to continue"

      Gettext.put_locale(VRWeb.Gettext, "ko")

      assert Gettext.gettext(VRWeb.Gettext, "You must sign in to continue") ==
               "로그인이 필요합니다"
    after
      Gettext.put_locale(VRWeb.Gettext, "en")
    end
  end
end
