defmodule VRWeb.Admin.MFAStepUpLiveTest do
  use VRWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import VR.AccountsFixtures

  alias VR.Accounts
  alias VR.Accounts.MFA
  alias VR.Repo

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, admin} = account |> Ecto.Changeset.change(%{is_admin: true}) |> Repo.update()
    {:ok, admin, _codes} = MFA.enable(admin, MFA.generate_secret(), "123456")

    {:ok, token, session} =
      Accounts.create_session(admin,
        mfa_verified_at: DateTime.add(DateTime.utc_now(:second), -601, :second)
      )

    conn = Plug.Test.init_test_session(conn, %{account_token: token})
    %{conn: conn, admin: admin, session: session}
  end

  test "성공한 MFA를 현재 세션에 기록하고 작업을 자동 실행하지 않은 채 돌아간다", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/_admin/accounts/verify-mfa")

    assert {:error, {:live_redirect, %{to: "/_admin/accounts"}}} =
             view |> form("form", %{code: "123456"}) |> render_submit()

    assert Repo.reload!(session).mfa_verified_at > session.mfa_verified_at
  end

  test "틀린 코드는 세션을 갱신하지 않는다", %{conn: conn, session: session} do
    {:ok, view, _html} = live(conn, ~p"/_admin/accounts/verify-mfa")

    assert view |> form("form", %{code: "wrong"}) |> render_submit() =~ "코드가 맞지 않습니다"
    assert Repo.reload!(session).mfa_verified_at == session.mfa_verified_at
  end
end
