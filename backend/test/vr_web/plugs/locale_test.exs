defmodule VRWeb.Plugs.LocaleTest do
  use VRWeb.ConnCase, async: true

  alias VRWeb.Plugs.Locale

  setup do
    # 각 테스트가 프로세스 로케일을 오염시키지 않도록 기본값으로 되돌린다.
    on_exit(fn -> Gettext.put_locale(VRWeb.Gettext, "en") end)
    :ok
  end

  defp run(conn, account) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> assign(:current_account, account)
    |> Locale.call(Locale.init([]))
  end

  test "계정의 locale 로 Gettext 로케일을 맞춘다", %{conn: conn} do
    conn = run(conn, %{locale: "ko"})

    assert Gettext.get_locale(VRWeb.Gettext) == "ko"
    assert conn.assigns.locale == "ko"
    assert get_session(conn, :locale) == "ko"
  end

  test "로그인하지 않았으면 영어로 떨어진다", %{conn: conn} do
    conn = run(conn, nil)

    assert Gettext.get_locale(VRWeb.Gettext) == "en"
    assert conn.assigns.locale == "en"
  end

  test "locale 이 비어 있으면 영어로 떨어진다", %{conn: conn} do
    conn = run(conn, %{locale: ""})

    assert Gettext.get_locale(VRWeb.Gettext) == "en"
    assert conn.assigns.locale == "en"
  end

  test "resolve/1 는 플러그와 on_mount 가 공유하는 규칙이다" do
    assert Locale.resolve(%{locale: "ja"}) == "ja"
    assert Locale.resolve(%{locale: nil}) == "en"
    assert Locale.resolve(nil) == "en"
    assert Locale.default_locale() == "en"
  end
end
