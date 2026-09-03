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

  test "records successful MFA on the current session and returns without auto-running the action", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/_admin/accounts/verify-mfa")

    assert {:error, {:live_redirect, %{to: "/_admin/accounts"}}} =
             view |> form("form", %{code: "123456"}) |> render_submit()

    assert Repo.reload!(session).mfa_verified_at > session.mfa_verified_at
  end

  test "a wrong code does not refresh the session", %{conn: conn, session: session} do
    {:ok, view, _html} = live(conn, ~p"/_admin/accounts/verify-mfa")

    assert view |> form("form", %{code: "wrong"}) |> render_submit() =~ "The code is incorrect."
    assert Repo.reload!(session).mfa_verified_at == session.mfa_verified_at
  end
end
