defmodule VRWeb.OAuthControllerTest do
  use VRWeb.ConnCase, async: false

  alias VR.Auth.Providers

  describe "GET /auth/:provider" do
    test "설정되지 않은 제공자는 404", %{conn: conn} do
      conn = get(conn, ~p"/auth/google")
      assert response(conn, 404)
    end

    test "키만 있고 꺼져 있으면 404", %{conn: conn} do
      {:ok, _} = Providers.upsert("google", %{"client_id" => "cid", "client_secret" => "sec"})
      conn = get(conn, ~p"/auth/google")
      assert response(conn, 404)
    end

    test "키가 있고 켜져 있으면 제공자로 리다이렉트한다", %{conn: conn} do
      {:ok, _} =
        Providers.upsert("google", %{
          "client_id" => "cid",
          "client_secret" => "sec",
          "redirect_uri" => "http://localhost:4000/auth/google/callback"
        })

      {:ok, _} = Providers.set_enabled("google", true)

      conn = get(conn, ~p"/auth/google")
      location = redirected_to(conn, 302)

      assert location =~ "accounts.google.com"
      assert location =~ "client_id=cid"
      # CSRF 방어용 state 가 세션에 저장되고 URL 에도 실린다
      state = get_session(conn, :oauth_state)
      assert is_binary(state)
      assert location =~ "state=#{state}"
    end

    test "지원하지 않는 제공자는 404", %{conn: conn} do
      conn = get(conn, ~p"/auth/myspace")
      assert response(conn, 404)
    end
  end

  describe "GET /auth/:provider/callback" do
    setup do
      {:ok, _} =
        Providers.upsert("google", %{
          "client_id" => "cid",
          "client_secret" => "sec",
          "redirect_uri" => "http://localhost:4000/auth/google/callback"
        })

      {:ok, _} = Providers.set_enabled("google", true)
      :ok
    end

    test "state 가 없으면 거부한다", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/callback?code=abc&state=forged")
      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "유효하지 않습니다"
    end

    test "state 가 다르면 거부한다", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{oauth_state: "real-state", oauth_provider: "google"})
        |> get(~p"/auth/google/callback?code=abc&state=forged-state")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "유효하지 않습니다"
    end

    test "사용자가 취소하면 안내 후 로그인으로 보낸다", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/callback?error=access_denied")
      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "취소"
    end
  end
end
