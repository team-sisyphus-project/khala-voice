defmodule VRWeb.LogoutTest do
  @moduledoc """
  Logout.

  **Killing only the session while leaving the "remember me" cookie logs the user
  back in on the next request.** Verify both are severed.
  """

  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts

  setup %{conn: conn} do
    account = account_fixture()

    conn =
      post(conn, ~p"/login", %{
        "account" => %{
          "email" => account.email,
          "password" => valid_password(),
          "remember_me" => "true"
        }
      })

    %{conn: conn, account: account}
  end

  defp session_count(account) do
    account.id |> Accounts.list_sessions() |> length()
  end

  describe "API logout (app)" do
    test "kills the session and clears the cookie", %{conn: conn, account: account} do
      assert session_count(account) == 1

      conn = conn |> recycle_session() |> delete(~p"/api/me/session")
      assert conn.status == 204

      assert session_count(account) == 0

      # Without clearing the cookie, the next request resurrects the login
      assert conn.resp_cookies["_vr_session"][:max_age] == 0
    end

    test "the API is blocked after logout", %{conn: conn} do
      conn = conn |> recycle_session() |> delete(~p"/api/me/session")

      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(Plug.Conn.get_session(conn))
        |> get(~p"/api/me")

      assert conn.status == 401
    end
  end

  describe "form logout (LiveView screens)" do
    test "sends you to the login screen", %{conn: conn, account: account} do
      conn = conn |> recycle_session() |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      assert session_count(account) == 0
    end
  end

  defp recycle_session(conn) do
    conn
    |> recycle()
    |> Plug.Test.init_test_session(Plug.Conn.get_session(conn))
  end
end
