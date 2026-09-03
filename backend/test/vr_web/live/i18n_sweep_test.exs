defmodule VRWeb.I18nSweepTest do
  @moduledoc """
  Regression dragnet for residual Korean across all screens (LiveView).

  While the per-screen tests (`app/screens_i18n_test.exs` and
  `auth/screens_i18n_test.exs`) check individual screens' copy, this suite sweeps
  **every post-login app LiveView** in one place, catching as regressions any
  hard-coded Korean leaking into the `en` render and verifying the `ko` render is
  actually Korean (not an English fallback). It is the server-side counterpart of
  the React i18n tests (`apps/web/src/i18n/*.test.ts`).

  The subject of inspection is **rendered markup**. The UI language picker's
  native name (Korean, "\uD55C\uAD6D\uC5B4") is an endonym, not a translation
  target (voice/base endonym rule), so it is stripped before checking.
  """
  use VRWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import VR.AccountsFixtures

  alias VR.Accounts
  alias VR.Friends

  # The Hangul-syllables block (U+AC00-U+D7A3). The `u` flag matches by codepoint
  # (no byte-range mismatches on multibyte characters — em-dashes and the like).
  @hangul ~r/[\x{AC00}-\x{D7A3}]/u

  # The settings screen's UI language picker endonym (native name for Korean) is not a translation target.
  @endonyms ["\uD55C\uAD6D\uC5B4"]

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

  describe "en account: no residual Korean on any app LiveView screen" do
    setup do
      %{account: confirmed_account_fixture(%{locale: "en", name: "Ada"})}
    end

    test "friends screen", %{conn: conn, account: account} do
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/friends")
      refute strip_endonyms(render(lv)) =~ @hangul
    end

    test "settings screen (endonyms excluded)", %{conn: conn, account: account} do
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/settings")
      refute strip_endonyms(render(lv)) =~ @hangul
    end

    test "invite screen (unauthenticated falls back to en)", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/invite/#{invite_token()}")
      refute strip_endonyms(render(lv)) =~ @hangul
    end
  end

  describe "ko account: every app LiveView screen renders in Korean (not the English fallback)" do
    setup do
      %{account: confirmed_account_fixture(%{locale: "ko", name: "Ada"})}
    end

    test "friends screen", %{conn: conn, account: account} do
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/friends")
      assert render(lv) =~ @hangul
    end

    test "settings screen", %{conn: conn, account: account} do
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/settings")
      assert render(lv) =~ @hangul
    end

    test "invite screen", %{conn: conn, account: account} do
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/invite/#{invite_token()}")
      assert render(lv) =~ @hangul
    end
  end

  describe "unauthenticated access-blocked flash" do
    # `UserAuth.require_authenticated` (controller plug) and `on_mount(:require_authenticated)`
    # (LiveView) share the same msgid. Unauthenticated users are always en (no account → fallback),
    # so the flash must come out in English — previously hard-coded Korean lingered on the login screen.
    test "en (default): the plug flash is English with no Korean", %{conn: conn} do
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

    test "LiveView mount: unauthenticated redirects to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/friends")
    end

    test "ko catalog: the translation exists", %{conn: _conn} do
      Gettext.put_locale(VRWeb.Gettext, "en")

      assert Gettext.gettext(VRWeb.Gettext, "You must sign in to continue") ==
               "You must sign in to continue"

      Gettext.put_locale(VRWeb.Gettext, "ko")

      # Korean for "You must sign in": expected ko catalog msgstr
      assert Gettext.gettext(VRWeb.Gettext, "You must sign in to continue") ==
               "\uB85C\uADF8\uC778\uC774 \uD544\uC694\uD569\uB2C8\uB2E4"
    after
      Gettext.put_locale(VRWeb.Gettext, "en")
    end
  end
end
