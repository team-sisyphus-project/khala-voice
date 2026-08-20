defmodule VRWeb.SessionControllerTest do
  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts

  setup do
    %{account: account_fixture()}
  end

  describe "POST /login" do
    test "올바른 자격증명이면 로그인된다", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => account.email, "password" => valid_password()}
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == "/go/meetings"
    end

    test "틀린 비밀번호는 계정 존재 여부를 알려주지 않는다", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => account.email, "password" => "wrong-password-xx"}
        })

      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "이메일 또는 비밀번호"
    end

    test "없는 계정도 같은 메시지를 준다", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => "nobody@example.test", "password" => valid_password()}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "이메일 또는 비밀번호"
    end

    test "실패가 쌓이면 잠긴다", %{conn: conn, account: account} do
      for _ <- 1..10 do
        Accounts.record_login_attempt(account.email, "127.0.0.1", false)
      end

      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => account.email, "password" => valid_password()}
        })

      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "너무 많습니다"
    end

    test "remember_me 를 주면 쿠키가 남는다", %{conn: conn, account: account} do
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
    test "세션이 무효화된다", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => account.email, "password" => valid_password()}
        })

      token = get_session(conn, :account_token)
      assert {:ok, _, _} = Accounts.get_account_by_session_token(token)

      conn = delete(recycle_with_session(conn), ~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      # 쿠키만 지우는 게 아니라 서버 세션도 끊는다
      assert :error = Accounts.get_account_by_session_token(token)
    end
  end

  describe "인증이 필요한 경로" do
    test "비로그인은 로그인으로 보낸다", %{conn: conn} do
      conn = get(conn, ~p"/app/meetings")
      assert redirected_to(conn) == ~p"/login"
    end

    test "로그인 상태면 통과한다", %{conn: conn, account: account} do
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
      # /app 아래는 React SPA 껍데기다. 화면 글자는 클라이언트가 그린다.
      assert html =~ ~s(<div id="root">)
    end
  end

  defp recycle_with_session(conn) do
    conn
    |> recycle()
    |> Plug.Test.init_test_session(Plug.Conn.get_session(conn))
  end
end
