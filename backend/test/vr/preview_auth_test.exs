defmodule VR.PreviewAuthTest do
  use VR.DataCase, async: true

  alias VR.Accounts
  alias VR.Accounts.Admin
  alias VR.PreviewAuth
  alias VR.Repo

  @password "preview-test-password"

  test "creates 1 admin, 2 regular users, and a recent MFA session" do
    assert {:ok, result} = PreviewAuth.ensure(password: @password)

    assert Enum.sort(Map.keys(result.accounts)) == [:admin, :user1, :user2]
    assert result.accounts.admin.email == "admin@khala.voice"
    assert result.accounts.admin.is_admin
    refute result.accounts.user1.is_admin
    refute result.accounts.user2.is_admin

    Enum.each(result.accounts, fn {_role, account} ->
      assert account.confirmed_at
      assert Accounts.get_account_by_email_and_password(account.email, @password)
    end)

    assert result.mfa_ttl_seconds == 600
    assert result.mfa_session.account_id == result.accounts.admin.id
    assert result.mfa_session.is_active

    assert DateTime.diff(DateTime.utc_now(:second), result.mfa_session.mfa_verified_at, :second) in 0..1

    assert {:ok, _} =
             Admin.promote(result.accounts.user1, result.accounts.admin, result.mfa_session)
  end

  test "re-running restores the required state without duplicating accounts or MFA sessions" do
    assert {:ok, first} = PreviewAuth.ensure(password: @password)

    first.accounts.admin
    |> Ecto.Changeset.change(%{is_admin: false})
    |> Repo.update!()

    first.accounts.user1
    |> Ecto.Changeset.change(%{is_admin: true})
    |> Repo.update!()

    assert {:ok, second} = PreviewAuth.ensure(password: @password)

    assert account_ids(first) == account_ids(second)
    assert first.mfa_session.id == second.mfa_session.id
    assert second.accounts.admin.is_admin
    refute second.accounts.user1.is_admin
    assert Repo.aggregate(VR.Accounts.Account, :count) == 3
    assert Repo.aggregate(VR.Accounts.AccountSession, :count) == 1
  end

  test "force-injects a recent MFA verification time into the admin's existing active sessions" do
    assert {:ok, initial} = PreviewAuth.ensure(password: @password)
    old = DateTime.add(DateTime.utc_now(:second), -601, :second)

    {:ok, _token, browser_session} =
      Accounts.create_session(initial.accounts.admin,
        user_agent: "preview-browser",
        mfa_verified_at: old
      )

    assert {:ok, _result} = PreviewAuth.ensure(password: @password)

    refreshed = Repo.reload!(browser_session)
    assert refreshed.mfa_verified_at > old
    assert DateTime.diff(DateTime.utc_now(:second), refreshed.mfa_verified_at, :second) in 0..1
  end

  test "creates no data when the password is missing or too short" do
    assert {:error, :password_required} = PreviewAuth.ensure(password: "")
    assert {:error, :password_too_short} = PreviewAuth.ensure(password: "short")
    assert Repo.aggregate(VR.Accounts.Account, :count) == 0
  end

  defp account_ids(result) do
    Map.new(result.accounts, fn {role, account} -> {role, account.id} end)
  end
end
