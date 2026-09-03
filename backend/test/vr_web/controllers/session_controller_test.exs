defmodule VRWeb.SessionControllerTest do
  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts

  setup do
    %{account: account_fixture()}
  end

  describe "POST /login" do
    test "correct credentials log in", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => account.email, "password" => valid_password()}
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == "/go/meetings"
    end

    test "a wrong password does not reveal whether the account exists", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => account.email, "password" => "wrong-password-xx"}
        })

      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ ~r/email or password/i
    end

    test "a nonexistent account gets the same message", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => "nobody@example.test", "password" => valid_password()}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ ~r/email or password/i
    end

    test "locks after accumulated failures", %{conn: conn, account: account} do
      for _ <- 1..10 do
        Accounts.record_login_attempt(account.email, "127.0.0.1", false)
      end

      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => account.email, "password" => valid_password()}
        })

      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ ~r/too many/i
    end

    test "remember_me leaves a cookie", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{
            "email" => account.email,
            "password" => valid_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_vr_session"]
      assert conn.resp_cookies["_vr_session"].http_only
      assert conn.resp_cookies["_vr_session"].same_site == "Lax"
    end
  end

  describe "DELETE /logout" do
    test "the session is invalidated", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => account.email, "password" => valid_password()}
        })

      token = get_session(conn, :account_token)
      assert {:ok, _, _} = Accounts.get_account_by_session_token(token)

      conn = delete(recycle_with_session(conn), ~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      # Not just clearing the cookie — the server session is severed too
      assert :error = Accounts.get_account_by_session_token(token)
    end
  end

  describe "routes requiring authentication" do
    test "unauthenticated is sent to login", %{conn: conn} do
      conn = get(conn, ~p"/app/meetings")
      assert redirected_to(conn) == ~p"/login"
    end

    test "passes when logged in", %{conn: conn, account: account} do
      _ = account

      conn =
        conn
        |> post(~p"/login", %{
          "account" => %{"email" => account.email, "password" => valid_password()}
        })
        |> recycle_with_session()
        |> get(~p"/app/meetings")

      html = html_response(conn, 200)
      assert html =~ "KHALA VOICE"
      # Everything under /app is the React SPA shell. The client renders the screen text.
      assert html =~ ~s(<div id="root">)
    end
  end

  defp recycle_with_session(conn) do
    conn
    |> recycle()
    |> Plug.Test.init_test_session(Plug.Conn.get_session(conn))
  end
end
