defmodule VRWeb.Plugs.LocaleTest do
  use VRWeb.ConnCase, async: true

  alias VRWeb.Plugs.Locale

  setup do
    # Restore the default so tests do not pollute the process locale.
    on_exit(fn -> Gettext.put_locale(VRWeb.Gettext, "en") end)
    :ok
  end

  defp run(conn, account) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> assign(:current_account, account)
    |> Locale.call(Locale.init([]))
  end

  test "sets the Gettext locale to the account locale", %{conn: conn} do
    conn = run(conn, %{locale: "ko"})

    assert Gettext.get_locale(VRWeb.Gettext) == "ko"
    assert conn.assigns.locale == "ko"
    assert get_session(conn, :locale) == "ko"
  end

  test "falls back to English when not logged in", %{conn: conn} do
    conn = run(conn, nil)

    assert Gettext.get_locale(VRWeb.Gettext) == "en"
    assert conn.assigns.locale == "en"
  end

  test "falls back to English when locale is empty", %{conn: conn} do
    conn = run(conn, %{locale: ""})

    assert Gettext.get_locale(VRWeb.Gettext) == "en"
    assert conn.assigns.locale == "en"
  end

  test "resolve/1 is the rule shared by the plug and on_mount" do
    assert Locale.resolve(%{locale: "ja"}) == "ja"
    assert Locale.resolve(%{locale: nil}) == "en"
    assert Locale.resolve(nil) == "en"
    assert Locale.default_locale() == "en"
  end
end
