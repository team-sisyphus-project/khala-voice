defmodule VRWeb.MFALoginTest do
  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts.MFA

  defp admin_with_mfa do
    account = account_fixture()
    {:ok, admin} = account |> Ecto.Changeset.change(%{is_admin: true}) |> VR.Repo.update()
    {:ok, enabled, codes} = MFA.enable(admin, MFA.generate_secret(), "123456")
    {enabled, codes}
  end

  defp login(conn, account) do
    post(conn, ~p"/login", %{
      "account" => %{"email" => account.email, "password" => valid_password()}
    })
  end

  defp recycle_session(conn) do
    conn |> recycle() |> Plug.Test.init_test_session(Plug.Conn.get_session(conn))
  end

  describe "accounts with MFA off" do
    test "logs straight in", %{conn: conn} do
      account = account_fixture()
      conn = login(conn, account)

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == "/go/meetings"
    end
  end

  describe "admins with MFA on" do
    test "the password alone creates no session", %{conn: conn} do
      {admin, _} = admin_with_mfa()
      conn = login(conn, admin)

      refute get_session(conn, :account_token)
      assert get_session(conn, :mfa_pending_account_id) == admin.id
      assert redirected_to(conn) == ~p"/login/mfa"
    end

    test "entering the code logs in", %{conn: conn} do
      {admin, _} = admin_with_mfa()

      conn =
        conn
        |> login(admin)
        |> recycle_session()
        |> post(~p"/login/mfa", %{"code" => "123456"})

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == "/go/meetings"

      assert {:ok, ^admin, session} =
               VR.Accounts.get_account_by_session_token(get_session(conn, :account_token))

      assert session.mfa_verified_at
      # The pending state is cleaned up
      refute get_session(conn, :mfa_pending_account_id)
    end

    test "a backup code passes too", %{conn: conn} do
      {admin, codes} = admin_with_mfa()

      conn =
        conn
        |> login(admin)
        |> recycle_session()
        |> post(~p"/login/mfa", %{"code" => hd(codes)})

      assert get_session(conn, :account_token)
    end

    test "a wrong code creates no session", %{conn: conn} do
      {admin, _} = admin_with_mfa()

      conn =
        conn
        |> login(admin)
        |> recycle_session()
        |> post(~p"/login/mfa", %{"code" => "wrongcode"})

      refute get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/login/mfa"
    end

    test "sending a code without a pending state is rejected", %{conn: conn} do
      conn = post(conn, ~p"/login/mfa", %{"code" => "123456"})

      refute get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/login"
    end

    test "expires after 5 minutes", %{conn: conn} do
      {admin, _} = admin_with_mfa()

      conn =
        conn
        |> login(admin)
        |> recycle_session()

      # Rewind as if it started 6 minutes ago
      stale = System.system_time(:second) - 360

      conn =
        conn
        |> Plug.Test.init_test_session(
          Map.put(Plug.Conn.get_session(conn), "mfa_pending_at", stale)
        )
        |> post(~p"/login/mfa", %{"code" => "123456"})

      refute get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/login"
    end

    test "the MFA screen sends you to login without a pending state", %{conn: conn} do
      conn = get(conn, ~p"/login/mfa")
      assert redirected_to(conn) == ~p"/login"
    end
  end

  describe "regular users" do
    test "not required even when enabled (admins only)", %{conn: conn} do
      user = account_fixture()
      {:ok, _enabled, _} = MFA.enable(user, MFA.generate_secret(), "123456")

      # MFA.required? also checks is_admin
      reloaded = VR.Repo.get!(VR.Accounts.Account, user.id)
      refute MFA.required?(reloaded)

      conn = login(conn, user)
      assert get_session(conn, :account_token)
    end
  end
end
