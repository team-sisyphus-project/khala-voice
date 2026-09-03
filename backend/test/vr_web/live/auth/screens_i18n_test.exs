defmodule VRWeb.AuthLive.ScreensI18nTest do
  @moduledoc """
  Verifies the auth screens in the login/signup flow are translated.

  Auth screens precede session establishment, so there is no `current_account` —
  the locale always resolves to the default (en); logged-in users never reach
  these screens thanks to `:redirect_if_authenticated`. Therefore:

  - Screen render checks: anonymous visits render in en with no hard-coded Korean left.
  - ko regression checks: the ko catalog actually translates the auth copy (direct
    catalog lookups). Hangul below is kept as Unicode escapes because these tests
    verify Korean-language handling specifically.
  """
  use VRWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import VR.AccountsFixtures

  # The Hangul-syllables block (U+AC00-U+D7A3). The `u` flag matches Unicode codepoints
  # (so multibyte characters like em-dashes are not mismatched by byte ranges).
  @hangul ~r/[\x{AC00}-\x{D7A3}]/u

  describe "login screen" do
    test "anonymous visits render in English with no Korean left", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/login")
      html = render(lv)

      assert html =~ "Sign in"
      assert html =~ "Record your meetings and organize them automatically"
      assert html =~ "Keep me signed in"
      assert html =~ "Forgot your password?"
      refute html =~ @hangul
    end
  end

  describe "signup screen" do
    test "anonymous visits render in English with no Korean left", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/register")
      html = render(lv)

      assert html =~ "Sign up"
      assert html =~ "At least 10 characters"
      assert html =~ "Already have an account?"
      refute html =~ @hangul
    end
  end

  describe "password reset request screen" do
    test "anonymous visits render in English with no Korean left", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/forgot-password")
      html = render(lv)

      assert html =~ "Reset password"
      assert html =~ "email you a reset link"
      assert html =~ "Send reset link"
      refute html =~ @hangul
    end
  end

  describe "new password screen" do
    test "anonymous visits render in English with no Korean left", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/reset-password/any-token")
      html = render(lv)

      assert html =~ "Set a new password"
      assert html =~ "New password"
      assert html =~ "Confirm password"
      refute html =~ @hangul
    end
  end

  describe "MFA verification code screen" do
    test "renders with the en fallback and no Korean left", %{conn: conn} do
      account = confirmed_account_fixture(%{name: "Ada"})
      conn = Plug.Test.init_test_session(conn, %{"mfa_pending_account_id" => account.id})

      {:ok, lv, _} = live(conn, ~p"/login/mfa")
      html = render(lv)

      assert html =~ "Verification code"
      assert html =~ "Enter the 6-digit code from your authenticator app"
      refute html =~ @hangul
    end
  end

  describe "MFA enrollment screen" do
    test "renders with the en fallback and no Korean left", %{conn: conn} do
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

  describe "ko catalog regression" do
    setup do
      Gettext.put_locale(VRWeb.Gettext, "ko")
      on_exit(fn -> Gettext.put_locale(VRWeb.Gettext, "en") end)
    end

    test "auth copy is translated into ko" do
      # Expected ko catalog msgstrs (Hangul kept as escapes; these verify Korean output)
      assert Gettext.gettext(VRWeb.Gettext, "Sign in") == "\uB85C\uADF8\uC778"
      assert Gettext.gettext(VRWeb.Gettext, "Sign up") == "\uAC00\uC785\uD558\uAE30"
      assert Gettext.gettext(VRWeb.Gettext, "Keep me signed in") == "\uB85C\uADF8\uC778 \uC0C1\uD0DC \uC720\uC9C0"
      assert Gettext.gettext(VRWeb.Gettext, "Reset password") == "\uBE44\uBC00\uBC88\uD638 \uC7AC\uC124\uC815"
      assert Gettext.gettext(VRWeb.Gettext, "Set a new password") == "\uC0C8 \uBE44\uBC00\uBC88\uD638 \uC124\uC815"
      assert Gettext.gettext(VRWeb.Gettext, "Verification code") == "\uC778\uC99D \uCF54\uB4DC"

      assert Gettext.gettext(VRWeb.Gettext, "Set up two-factor authentication") ==
               "2\uB2E8\uACC4 \uC778\uC99D \uC124\uC815"

      assert Gettext.gettext(VRWeb.Gettext, "Turn on and continue") == "\uCF1C\uACE0 \uACC4\uC18D"
    end

    test "the OAuth provider interpolation copy is translated into ko" do
      # Korean: "Continue with Google"
      assert Gettext.gettext(VRWeb.Gettext, "Continue with %{provider}", provider: "Google") ==
               "Google\uB85C \uACC4\uC18D\uD558\uAE30"
    end
  end
end
