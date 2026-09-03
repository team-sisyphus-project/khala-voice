defmodule VRWeb.OAuthControllerTest do
  use VRWeb.ConnCase, async: false

  alias VR.Auth.Providers

  describe "GET /auth/:provider" do
    test "an unconfigured provider is 404", %{conn: conn} do
      conn = get(conn, ~p"/auth/google")
      assert response(conn, 404)
    end

    test "credentials without enablement is 404", %{conn: conn} do
      {:ok, _} = Providers.upsert("google", %{"client_id" => "cid", "client_secret" => "sec"})
      conn = get(conn, ~p"/auth/google")
      assert response(conn, 404)
    end

    test "with credentials and enabled, redirects to the provider", %{conn: conn} do
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
      # The CSRF-defense state is stored in the session and carried in the URL
      state = get_session(conn, :oauth_state)
      assert is_binary(state)
      assert location =~ "state=#{state}"
    end

    test "an unsupported provider is 404", %{conn: conn} do
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

    test "rejects without state", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/callback?code=abc&state=forged")
      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ ~r/valid/i
    end

    test "rejects a mismatched state", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{oauth_state: "real-state", oauth_provider: "google"})
        |> get(~p"/auth/google/callback?code=abc&state=forged-state")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ ~r/valid/i
    end

    test "user cancellation notifies and sends to login", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/callback?error=access_denied")
      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ ~r/cancel/i
    end
  end
end
