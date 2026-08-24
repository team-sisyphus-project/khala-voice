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

  describe "MFA 가 꺼진 계정" do
    test "바로 로그인된다", %{conn: conn} do
      account = account_fixture()
      conn = login(conn, account)

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == "/go/meetings"
    end
  end

  describe "MFA 가 켜진 어드민" do
    test "비밀번호만으로는 세션이 생기지 않는다", %{conn: conn} do
      {admin, _} = admin_with_mfa()
      conn = login(conn, admin)

      refute get_session(conn, :account_token)
      assert get_session(conn, :mfa_pending_account_id) == admin.id
      assert redirected_to(conn) == ~p"/login/mfa"
    end

    test "코드를 넣으면 로그인된다", %{conn: conn} do
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
      # 대기 상태는 정리된다
      refute get_session(conn, :mfa_pending_account_id)
    end

    test "백업 코드로도 통과한다", %{conn: conn} do
      {admin, codes} = admin_with_mfa()

      conn =
        conn
        |> login(admin)
        |> recycle_session()
        |> post(~p"/login/mfa", %{"code" => hd(codes)})

      assert get_session(conn, :account_token)
    end

    test "틀린 코드는 세션을 만들지 않는다", %{conn: conn} do
      {admin, _} = admin_with_mfa()

      conn =
        conn
        |> login(admin)
        |> recycle_session()
        |> post(~p"/login/mfa", %{"code" => "틀린코드"})

      refute get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/login/mfa"
    end

    test "대기 상태 없이 코드만 보내면 거부한다", %{conn: conn} do
      conn = post(conn, ~p"/login/mfa", %{"code" => "123456"})

      refute get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/login"
    end

    test "5분이 지나면 만료된다", %{conn: conn} do
      {admin, _} = admin_with_mfa()

      conn =
        conn
        |> login(admin)
        |> recycle_session()

      # 6분 전에 시작한 것으로 되돌린다
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

    test "MFA 화면은 대기 상태가 없으면 로그인으로 보낸다", %{conn: conn} do
      conn = get(conn, ~p"/login/mfa")
      assert redirected_to(conn) == ~p"/login"
    end
  end

  describe "일반 사용자" do
    test "MFA 를 켜도 요구하지 않는다 (어드민만 해당)", %{conn: conn} do
      user = account_fixture()
      {:ok, _enabled, _} = MFA.enable(user, MFA.generate_secret(), "123456")

      # MFA.required? 는 is_admin 도 함께 본다
      reloaded = VR.Repo.get!(VR.Accounts.Account, user.id)
      refute MFA.required?(reloaded)

      conn = login(conn, user)
      assert get_session(conn, :account_token)
    end
  end
end
