defmodule VR.Accounts.AdminTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts
  alias VR.Accounts.Admin
  alias VR.AdminAudit
  alias VR.Config

  defp admin_fixture(attrs \\ %{}) do
    account = account_fixture(attrs)
    {:ok, updated} = account |> Ecto.Changeset.change(%{is_admin: true}) |> VR.Repo.update()
    updated
  end

  defp recent_session(actor, seconds_ago \\ 0) do
    {:ok, _token, session} =
      Accounts.create_session(actor,
        mfa_verified_at: DateTime.add(DateTime.utc_now(:second), -seconds_ago, :second)
      )

    session
  end

  describe "bootstrap" do
    test "reads email and password from the shared config layer" do
      {:ok, _} = Config.put("app.bootstrap_admin_email", "configured@test.local")
      {:ok, _} = Config.put("app.bootstrap_admin_password", "configured-password-1234")

      assert {:ok, account, "configured-password-1234"} =
               Admin.ensure_bootstrap_admin()

      assert account.email == "configured@test.local"

      assert Accounts.get_account_by_email_and_password(
               "configured@test.local",
               "configured-password-1234"
             )
    end

    test "creates an admin when none exists" do
      assert {:ok, account, password} = Admin.ensure_bootstrap_admin(email: "boot@test.local")

      assert account.is_admin
      assert account.is_bootstrap
      assert account.confirmed_at
      assert byte_size(password) >= 16
    end

    test "the generated password logs in immediately" do
      {:ok, account, password} = Admin.ensure_bootstrap_admin(email: "boot2@test.local")
      assert Accounts.get_account_by_email_and_password(account.email, password)
    end

    test "the password is not stored in plaintext" do
      {:ok, account, password} = Admin.ensure_bootstrap_admin(email: "boot3@test.local")

      %{rows: [[stored]]} =
        VR.Repo.query!("SELECT hashed_password FROM accounts WHERE id = $1", [account.id])

      refute String.contains?(stored, password)
    end

    test "does not create when an admin already exists" do
      _ = admin_fixture()
      assert {:error, :admin_exists} = Admin.ensure_bootstrap_admin(email: "boot@test.local")
    end

    test "does not create without an email — no default address" do
      assert {:error, :email_required} = Admin.ensure_bootstrap_admin()
    end

    test "repeated runs create only one" do
      assert {:ok, _, _} = Admin.ensure_bootstrap_admin(email: "boot4@test.local")
      assert {:error, :admin_exists} = Admin.ensure_bootstrap_admin(email: "boot5@test.local")
      assert Admin.count_admins() == 1
    end

    test "the bootstrap account can be found" do
      {:ok, account, _} = Admin.ensure_bootstrap_admin(email: "boot6@test.local")
      assert Admin.bootstrap_account().id == account.id
    end
  end

  describe "promotion" do
    test "records success and denial as masked structured events" do
      actor = admin_fixture(email: "Audit.Actor@Example.test")
      target = account_fixture(email: "Audit.Target@Example.test")

      assert {:error, :recent_mfa_required} = Admin.promote(target, actor)
      assert {:ok, _promoted} = Admin.promote(target, actor, recent_session(actor))

      assert {:ok, events} =
               AdminAudit.search(
                 action: "admin.promote",
                 actor_account_id: actor.id,
                 target_account_id: target.id
               )

      assert length(events) == 2
      succeeded = Enum.find(events, &(&1.outcome == "succeeded"))
      denied = Enum.find(events, &(&1.outcome == "denied"))

      assert succeeded.outcome == "succeeded"
      assert succeeded.reason == "completed"
      assert succeeded.actor_email_masked == "a***@***.test"
      assert succeeded.target_email_masked == "a***@***.test"
      assert denied.outcome == "denied"
      assert denied.reason == "recent_mfa_required"
    end

    test "if the audit event cannot be written, the permission change rolls back too" do
      actor = admin_fixture()
      target = account_fixture()
      Logger.metadata(request_id: String.duplicate("x", 256))

      assert {:error, :audit_write_failed} =
               Admin.promote(target, actor, recent_session(actor))

      refute VR.Repo.reload!(target).is_admin
      Logger.metadata(request_id: nil)
    end

    test "rejects without recent MFA or past 10 minutes; allows a recent MFA session" do
      actor = admin_fixture()
      target = account_fixture()

      assert {:error, :recent_mfa_required} = Admin.promote(target, actor)

      assert {:error, :recent_mfa_required} =
               Admin.promote(target, actor, recent_session(actor, 601))

      assert {:ok, promoted} = Admin.promote(target, actor, recent_session(actor))
      assert promoted.is_admin
    end

    test "rejects when a regular user calls it directly" do
      actor = account_fixture()
      target = account_fixture()

      assert {:error, :unauthorized} = Admin.promote(target, actor)
      refute VR.Repo.reload!(target).is_admin
    end

    test "makes a regular account an admin" do
      actor = admin_fixture()
      target = account_fixture()

      assert {:ok, promoted} = Admin.promote(target, actor, recent_session(actor))
      assert promoted.is_admin
      assert Admin.count_admins() == 2
    end

    test "leaves an existing admin as-is" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:ok, same} = Admin.promote(target, actor, recent_session(actor))
      assert same.is_admin
    end

    test "a deleted account cannot be promoted" do
      actor = admin_fixture()
      target = account_fixture()
      {:ok, deleted} = Admin.delete_account(target, actor, recent_session(actor))

      assert {:error, :account_deleted} = Admin.promote(deleted, actor, recent_session(actor))
    end
  end

  describe "demotion — lockout prevention" do
    test "records success and denial as masked structured events" do
      actor = admin_fixture(email: "Demote.Actor@Ops.example")
      target = admin_fixture(email: "Demote.Target@People.example")

      assert {:error, :recent_mfa_required} = Admin.demote(target, actor)
      assert {:ok, _demoted} = Admin.demote(target, actor, recent_session(actor))

      assert {:ok, events} =
               AdminAudit.search(
                 action: "admin.demote",
                 actor_account_id: actor.id,
                 target_account_id: target.id
               )

      assert Enum.map(events, &{&1.outcome, &1.reason}) |> Enum.sort() ==
               [{"denied", "recent_mfa_required"}, {"succeeded", "completed"}]

      assert Enum.all?(events, fn event ->
               event.actor_email_masked == "d***@***.example" and
                 event.target_email_masked == "d***@***.example"
             end)
    end

    test "rejects without recent or with expired MFA; allows a recent MFA session" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:error, :recent_mfa_required} = Admin.demote(target, actor)

      assert {:error, :recent_mfa_required} =
               Admin.demote(target, actor, recent_session(actor, 601))

      assert {:ok, demoted} = Admin.demote(target, actor, recent_session(actor))
      refute demoted.is_admin
    end

    test "rejects when a regular user calls it directly" do
      actor = account_fixture()
      target = admin_fixture()

      assert {:error, :unauthorized} = Admin.demote(target, actor)
      assert VR.Repo.reload!(target).is_admin
    end

    test "the last admin cannot be demoted" do
      only_admin = admin_fixture()
      other = admin_fixture()

      session = recent_session(only_admin)
      assert {:ok, _} = Admin.demote(other, only_admin, session)
      assert Admin.count_admins() == 1

      # Both self and last admin. Both conditions apply, but the more
      # specific self check fires first — a message the user understands better.
      assert {:error, :cannot_demote_self} = Admin.demote(only_admin, only_admin, session)
      assert Admin.count_admins() == 1

      # Another admin trying to demote the last one is blocked by last_admin
      third = account_fixture()
      {:ok, third_admin} = Admin.promote(third, only_admin, session)
      third_session = recent_session(third_admin)
      {:ok, _} = Admin.demote(only_admin, third_admin, third_session)
      assert Admin.count_admins() == 1
      assert {:error, :cannot_demote_self} = Admin.demote(third_admin, third_admin, third_session)
    end

    test "cannot demote yourself" do
      actor = admin_fixture()
      _other = admin_fixture()

      assert {:error, :cannot_demote_self} = Admin.demote(actor, actor, recent_session(actor))
    end

    test "another admin can be demoted" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:ok, demoted} = Admin.demote(target, actor, recent_session(actor))
      refute demoted.is_admin
    end

    test "a non-admin target is a no-op" do
      actor = admin_fixture()
      target = account_fixture()

      assert {:ok, same} = Admin.demote(target, actor, recent_session(actor))
      refute same.is_admin
    end
  end

  describe "deletion — lockout prevention" do
    test "records success and denial as structured events masking the pre-deletion email" do
      actor = admin_fixture(email: "Delete.Actor@Ops.example")
      target = account_fixture(email: "Delete.Target@People.example")

      assert {:error, :recent_mfa_required} = Admin.delete_account(target, actor)
      assert {:ok, deleted} = Admin.delete_account(target, actor, recent_session(actor))
      assert deleted.email =~ "deleted.invalid"

      assert {:ok, events} =
               AdminAudit.search(
                 action: "account.delete",
                 actor_account_id: actor.id,
                 target_account_id: target.id
               )

      assert Enum.map(events, &{&1.outcome, &1.reason}) |> Enum.sort() ==
               [{"denied", "recent_mfa_required"}, {"succeeded", "completed"}]

      assert Enum.all?(events, fn event ->
               event.actor_email_masked == "d***@***.example" and
                 event.target_email_masked == "d***@***.example"
             end)
    end

    test "rejects without recent or with expired MFA; allows a recent MFA session" do
      actor = admin_fixture()
      target = account_fixture()

      assert {:error, :recent_mfa_required} = Admin.delete_account(target, actor)

      assert {:error, :recent_mfa_required} =
               Admin.delete_account(target, actor, recent_session(actor, 601))

      assert {:ok, deleted} = Admin.delete_account(target, actor, recent_session(actor))
      assert deleted.deleted_at
    end

    test "another actor's MFA session is not accepted" do
      actor = admin_fixture()
      other = admin_fixture()
      target = account_fixture()

      assert {:error, :recent_mfa_required} =
               Admin.delete_account(target, actor, recent_session(other))

      refute VR.Repo.reload!(target).deleted_at
    end

    test "MFA on a revoked session is not accepted" do
      actor = admin_fixture()
      target = account_fixture()
      session = recent_session(actor)
      {:ok, revoked} = session |> Ecto.Changeset.change(%{is_active: false}) |> VR.Repo.update()

      assert {:error, :recent_mfa_required} = Admin.delete_account(target, actor, revoked)
      refute VR.Repo.reload!(target).deleted_at
    end

    test "rejects when a regular user calls it directly" do
      actor = account_fixture()
      target = account_fixture()

      assert {:error, :unauthorized} = Admin.delete_account(target, actor)
      refute VR.Repo.reload!(target).deleted_at
    end

    test "cannot delete yourself" do
      actor = admin_fixture()

      assert {:error, :cannot_delete_self} =
               Admin.delete_account(actor, actor, recent_session(actor))
    end

    test "the last admin cannot be deleted" do
      actor = admin_fixture()
      last = admin_fixture()

      session = recent_session(actor)
      {:ok, demoted} = Admin.demote(last, actor, session)
      assert {:ok, _} = Admin.delete_account(demoted, actor, session)

      assert {:error, :cannot_delete_self} = Admin.delete_account(actor, actor, session)
    end

    test "an admin can be deleted when another admin exists" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:ok, deleted} = Admin.delete_account(target, actor, recent_session(actor))
      assert deleted.deleted_at
      refute deleted.is_admin
    end

    test "deletion anonymizes the email" do
      actor = admin_fixture()
      target = account_fixture(email: "victim@test.local")

      {:ok, deleted} = Admin.delete_account(target, actor, recent_session(actor))

      refute deleted.email == "victim@test.local"
      assert deleted.email =~ "deleted.invalid"
      assert is_nil(deleted.hashed_password)

      assert {:ok, _} =
               Accounts.register_account(%{
                 email: "victim@test.local",
                 password: valid_password()
               })
    end

    test "deletion cleans up sessions and friendships" do
      actor = admin_fixture()
      target = account_fixture()
      friend = account_fixture()

      {:ok, token, _} = Accounts.create_session(target)
      {:ok, _} = VR.Friends.create_friendship(target.id, friend.id)

      {:ok, _} = Admin.delete_account(target, actor, recent_session(actor))

      assert :error = Accounts.get_account_by_session_token(token)
      assert VR.Friends.list_friends(friend.id) == []
    end

    test "an already-deleted account cannot be deleted again" do
      actor = admin_fixture()
      target = account_fixture()

      session = recent_session(actor)
      {:ok, deleted} = Admin.delete_account(target, actor, session)
      assert {:error, :already_deleted} = Admin.delete_account(deleted, actor, session)
    end
  end

  describe "closing the bootstrap door (real-world scenario)" do
    test "after promoting a real user, the temporary account can be deleted" do
      {:ok, boot, _password} = Admin.ensure_bootstrap_admin(email: "boot@test.local")
      assert Admin.count_admins() == 1
      assert Admin.bootstrap_account()

      real = account_fixture(email: "real@test.local")

      {:ok, real_admin} = Admin.promote(real, boot, recent_session(boot))
      assert Admin.count_admins() == 2

      assert {:ok, _} = Admin.delete_account(boot, real_admin, recent_session(real_admin))
      assert Admin.count_admins() == 1
      assert is_nil(Admin.bootstrap_account())

      refute Accounts.get_account_by_email("boot@test.local")
    end

    test "the temporary account cannot be deleted before promotion (lockout prevention)" do
      {:ok, boot, _} = Admin.ensure_bootstrap_admin(email: "boot@test.local")

      assert {:error, :cannot_delete_self} =
               Admin.delete_account(boot, boot, recent_session(boot))

      assert Admin.count_admins() == 1
    end
  end

  describe "capabilities/2 — UI button decisions" do
    test "blocks demote and delete for the last admin" do
      only = admin_fixture()
      caps = Admin.capabilities(only, only)

      refute caps.can_demote
      refute caps.can_delete
      assert caps.is_self
      assert caps.is_last_admin
    end

    test "opens up when another admin exists" do
      actor = admin_fixture()
      target = admin_fixture()
      caps = Admin.capabilities(target, actor)

      assert caps.can_demote
      assert caps.can_delete
      refute caps.is_self
    end

    test "a regular account can be promoted" do
      actor = admin_fixture()
      target = account_fixture()
      caps = Admin.capabilities(target, actor)

      assert caps.can_promote
      refute caps.can_demote
      assert caps.can_delete
    end
  end

  describe "listing" do
    test "search and filters work" do
      _actor = admin_fixture(email: "admin@test.local", name: "Administrator")
      _user = account_fixture(email: "someone@test.local", name: "Jane Doe")

      assert length(Admin.list_accounts()) == 2
      assert [%{email: "admin@test.local"}] = Admin.list_accounts(only: :admins)
      assert [%{name: "Jane Doe"}] = Admin.list_accounts(q: "Jane D")
      assert [%{email: "admin@test.local"}] = Admin.list_accounts(q: "admin@")
    end

    test "deleted accounts are hidden by default" do
      actor = admin_fixture()
      target = account_fixture()
      {:ok, _} = Admin.delete_account(target, actor, recent_session(actor))

      assert length(Admin.list_accounts()) == 1
      assert length(Admin.list_accounts(only: :deleted)) == 1
    end
  end
end
