defmodule VRWeb.AppLive.ScreensI18nTest do
  @moduledoc """
  Verifies the post-login app screens (friends, settings, invite) translate
  according to the account `locale`.

  - `en` account: no hard-coded Korean remains on screen.
  - `ko` account: the existing Korean copy shows as-is.

  The UI language picker's native names (the Korean and Japanese endonyms, etc.)
  are not translation targets, so the settings screen's Korean check is narrowed
  to **UI copy** rather than native names. Hangul below is kept as Unicode escapes
  because these tests verify Korean-language rendering specifically.
  """
  use VRWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import VR.AccountsFixtures

  alias VR.Accounts
  alias VR.Friends

  # The Hangul-syllables block (U+AC00-U+D7A3). Detects whether Korean renders on screen.
  # The root layout's (`root.html.heex`) JS comments are outside this grain, so only the
  # LiveView's own render body (`render/1`) is inspected.
  @hangul ~r/[\x{AC00}-\x{D7A3}]/u

  defp log_in(conn, account) do
    {:ok, token, _} = Accounts.create_session(account)
    Plug.Test.init_test_session(conn, %{account_token: token})
  end

  describe "friends screen" do
    test "an en account renders in English with no Korean left", %{conn: conn} do
      account = confirmed_account_fixture(%{locale: "en", name: "Ada"})
      {:ok, lv, _} = conn |> log_in(account) |> live(~p"/friends")
      html = render(lv)

      assert html =~ "Invite"
      assert html =~ "Share meeting notes with friends"
      assert html =~ "No friends yet"
      refute html =~ @hangul
    end

    test "a ko account renders in Korean", %{conn: conn} do
      account = confirmed_account_fixture(%{locale: "ko", name: "Ada"})
      {:ok, _lv, html} = conn |> log_in(account) |> live(~p"/friends")

      # Korean: "Invite" / "No friends yet"
      assert html =~ "\uCD08\uB300\uD558\uAE30"
      assert html =~ "\uC544\uC9C1 \uCE5C\uAD6C\uAC00 \uC5C6\uC2B5\uB2C8\uB2E4"
    end
  end

  describe "settings screen" do
    # The language picker's native names (the Korean endonym, etc.) always render, so
    # instead of a blanket Hangul check we verify the Korean UI copy is gone.
    test "an en account renders with English UI copy", %{conn: conn} do
      account = confirmed_account_fixture(%{locale: "en", name: "Ada"})
      {:ok, _lv, html} = conn |> log_in(account) |> live(~p"/settings")

      assert html =~ "Account settings"
      assert html =~ "Profile"
      assert html =~ "Signed-in devices"
      assert html =~ "Delete account"

      # Korean: "Profile" / "Password" / "Signed-in devices" / "Delete account"
      refute html =~ "\uD504\uB85C\uD544"
      refute html =~ "\uBE44\uBC00\uBC88\uD638"
      refute html =~ "\uB85C\uADF8\uC778\uB41C \uAE30\uAE30"
      refute html =~ "\uACC4\uC815 \uC0AD\uC81C"
    end

    test "a ko account renders with Korean UI copy", %{conn: conn} do
      account = confirmed_account_fixture(%{locale: "ko", name: "Ada"})
      {:ok, _lv, html} = conn |> log_in(account) |> live(~p"/settings")

      # Korean: "Profile" / "Signed-in devices" / "Delete account"
      assert html =~ "\uD504\uB85C\uD544"
      assert html =~ "\uB85C\uADF8\uC778\uB41C \uAE30\uAE30"
      assert html =~ "\uACC4\uC815 \uC0AD\uC81C"
    end
  end

  describe "invite screen (unauthenticated)" do
    defp invitation_token(locale) do
      inviter = confirmed_account_fixture(%{name: "Grace"})
      {:ok, _invitation, token} = Friends.create_invitation(inviter, %{email: ""})
      {token, locale}
    end

    test "an en requester renders in English with no Korean left", %{conn: conn} do
      # The unauthenticated invite screen renders with the fallback (en).
      {token, _} = invitation_token("en")
      {:ok, lv, _} = live(conn, ~p"/invite/#{token}")
      html = render(lv)

      assert html =~ "Friend invitation"
      assert html =~ "invited you as a friend."
      assert html =~ "Sign in"
      assert html =~ "Sign up"
      refute html =~ @hangul
    end

    test "opened with a ko account it renders in Korean", %{conn: conn} do
      account = confirmed_account_fixture(%{locale: "ko", name: "Ada"})
      {token, _} = invitation_token("ko")
      {:ok, _lv, html} = conn |> log_in(account) |> live(~p"/invite/#{token}")

      # Korean: "Friend invitation" / "... invited you as a friend."
      assert html =~ "\uCE5C\uAD6C \uCD08\uB300"
      assert html =~ "\uB2D8\uC774 \uCE5C\uAD6C\uB85C \uCD08\uB300\uD588\uC2B5\uB2C8\uB2E4."
    end
  end
end
