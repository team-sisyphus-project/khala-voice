defmodule VRWeb.LocaleIntegrationTest do
  @moduledoc """
  Verifies the account `locale` flows all the way into the actual render.

  - Controller path: `VRWeb.Plugs.Locale` in the `:browser` pipeline.
  - LiveView path: `VRWeb.UserAuth.on_mount(:set_locale, ...)`.

  Both paths are observed via `<html lang>` in the root layout.
  """
  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts

  defp log_in(conn, account) do
    {:ok, token, _} = Accounts.create_session(account)
    Plug.Test.init_test_session(conn, %{account_token: token})
  end

  describe "LiveView render (on_mount :set_locale)" do
    test "an en account renders with <html lang=en>", %{conn: conn} do
      account = account_fixture(%{locale: "en"})
      conn = conn |> log_in(account) |> get(~p"/settings")

      assert html_response(conn, 200) =~ ~s(<html lang="en")
    end

    test "a ko account renders with <html lang=ko>", %{conn: conn} do
      account = account_fixture(%{locale: "ko"})
      conn = conn |> log_in(account) |> get(~p"/settings")

      assert html_response(conn, 200) =~ ~s(<html lang="ko")
    end
  end

  describe "LiveView render — fallback" do
    test "unauthenticated pages fall back to English", %{conn: conn} do
      conn = get(conn, ~p"/login")

      assert html_response(conn, 200) =~ ~s(<html lang="en")
    end
  end

  describe "controller pipeline (Plugs.Locale)" do
    # React SPA entry pages send the static index.html verbatim, bypassing the root
    # layout. So the controller path is observed not via `<html lang>` but via the
    # session `:locale` the plug plants (paired with the request process Gettext locale).
    test "browser requests plant the account locale in the session", %{conn: conn} do
      account = account_fixture(%{locale: "ko"})
      conn = conn |> log_in(account) |> get(~p"/")

      assert get_session(conn, :locale) == "ko"
    end

    test "unauthenticated browser requests plant English in the session", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert get_session(conn, :locale) == "en"
    end
  end
end
