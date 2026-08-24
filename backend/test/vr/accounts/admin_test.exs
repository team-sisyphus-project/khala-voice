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

  describe "부트스트랩" do
    test "공통 설정 계층에서 이메일과 비밀번호를 읽는다" do
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

    test "어드민이 없으면 만든다" do
      assert {:ok, account, password} = Admin.ensure_bootstrap_admin(email: "boot@test.local")

      assert account.is_admin
      assert account.is_bootstrap
      assert account.confirmed_at
      assert byte_size(password) >= 16
    end

    test "만든 비밀번호로 바로 로그인된다" do
      {:ok, account, password} = Admin.ensure_bootstrap_admin(email: "boot2@test.local")
      assert Accounts.get_account_by_email_and_password(account.email, password)
    end

    test "비밀번호를 평문으로 저장하지 않는다" do
      {:ok, account, password} = Admin.ensure_bootstrap_admin(email: "boot3@test.local")

      %{rows: [[stored]]} =
        VR.Repo.query!("SELECT hashed_password FROM accounts WHERE id = $1", [account.id])

      refute String.contains?(stored, password)
    end

    test "어드민이 이미 있으면 만들지 않는다" do
      _ = admin_fixture()
      assert {:error, :admin_exists} = Admin.ensure_bootstrap_admin(email: "boot@test.local")
    end

    test "이메일 없이는 만들지 않는다 — 기본 주소를 두지 않는다" do
      assert {:error, :email_required} = Admin.ensure_bootstrap_admin()
    end

    test "여러 번 실행해도 하나만 만든다" do
      assert {:ok, _, _} = Admin.ensure_bootstrap_admin(email: "boot4@test.local")
      assert {:error, :admin_exists} = Admin.ensure_bootstrap_admin(email: "boot5@test.local")
      assert Admin.count_admins() == 1
    end

    test "부트스트랩 계정을 찾을 수 있다" do
      {:ok, account, _} = Admin.ensure_bootstrap_admin(email: "boot6@test.local")
      assert Admin.bootstrap_account().id == account.id
    end
  end

  describe "승격" do
    test "성공과 거부 시도를 마스킹된 구조화 이벤트로 남긴다" do
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

    test "감사 이벤트를 쓸 수 없으면 권한 변경도 롤백한다" do
      actor = admin_fixture()
      target = account_fixture()
      Logger.metadata(request_id: String.duplicate("x", 256))

      assert {:error, :audit_write_failed} =
               Admin.promote(target, actor, recent_session(actor))

      refute VR.Repo.reload!(target).is_admin
      Logger.metadata(request_id: nil)
    end

    test "최근 MFA가 없거나 10분을 넘기면 거부하고 최근 MFA 세션은 허용한다" do
      actor = admin_fixture()
      target = account_fixture()

      assert {:error, :recent_mfa_required} = Admin.promote(target, actor)

      assert {:error, :recent_mfa_required} =
               Admin.promote(target, actor, recent_session(actor, 601))

      assert {:ok, promoted} = Admin.promote(target, actor, recent_session(actor))
      assert promoted.is_admin
    end

    test "일반 사용자가 직접 호출하면 거부한다" do
      actor = account_fixture()
      target = account_fixture()

      assert {:error, :unauthorized} = Admin.promote(target, actor)
      refute VR.Repo.reload!(target).is_admin
    end

    test "일반 계정을 어드민으로 만든다" do
      actor = admin_fixture()
      target = account_fixture()

      assert {:ok, promoted} = Admin.promote(target, actor, recent_session(actor))
      assert promoted.is_admin
      assert Admin.count_admins() == 2
    end

    test "이미 어드민이면 그대로 둔다" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:ok, same} = Admin.promote(target, actor, recent_session(actor))
      assert same.is_admin
    end

    test "삭제된 계정은 승격할 수 없다" do
      actor = admin_fixture()
      target = account_fixture()
      {:ok, deleted} = Admin.delete_account(target, actor, recent_session(actor))

      assert {:error, :account_deleted} = Admin.promote(deleted, actor, recent_session(actor))
    end
  end

  describe "강등 — 잠금 방지" do
    test "성공과 거부 시도를 마스킹된 구조화 이벤트로 남긴다" do
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

    test "최근 MFA가 없거나 만료되면 거부하고 최근 MFA 세션은 허용한다" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:error, :recent_mfa_required} = Admin.demote(target, actor)

      assert {:error, :recent_mfa_required} =
               Admin.demote(target, actor, recent_session(actor, 601))

      assert {:ok, demoted} = Admin.demote(target, actor, recent_session(actor))
      refute demoted.is_admin
    end

    test "일반 사용자가 직접 호출하면 거부한다" do
      actor = account_fixture()
      target = admin_fixture()

      assert {:error, :unauthorized} = Admin.demote(target, actor)
      assert VR.Repo.reload!(target).is_admin
    end

    test "마지막 어드민은 강등할 수 없다" do
      only_admin = admin_fixture()
      other = admin_fixture()

      session = recent_session(only_admin)
      assert {:ok, _} = Admin.demote(other, only_admin, session)
      assert Admin.count_admins() == 1

      # 자기 자신이면서 마지막 어드민이다. 두 조건 모두 걸리는데
      # 더 구체적인 self 검사가 먼저 잡는다 — 사용자에게 더 알아듣기 쉬운 메시지다.
      assert {:error, :cannot_demote_self} = Admin.demote(only_admin, only_admin, session)
      assert Admin.count_admins() == 1

      # 다른 어드민이 마지막 하나를 강등하려 하면 last_admin 으로 막힌다
      third = account_fixture()
      {:ok, third_admin} = Admin.promote(third, only_admin, session)
      third_session = recent_session(third_admin)
      {:ok, _} = Admin.demote(only_admin, third_admin, third_session)
      assert Admin.count_admins() == 1
      assert {:error, :cannot_demote_self} = Admin.demote(third_admin, third_admin, third_session)
    end

    test "자기 자신은 강등할 수 없다" do
      actor = admin_fixture()
      _other = admin_fixture()

      assert {:error, :cannot_demote_self} = Admin.demote(actor, actor, recent_session(actor))
    end

    test "다른 어드민은 강등할 수 있다" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:ok, demoted} = Admin.demote(target, actor, recent_session(actor))
      refute demoted.is_admin
    end

    test "어드민이 아니면 아무 일도 없다" do
      actor = admin_fixture()
      target = account_fixture()

      assert {:ok, same} = Admin.demote(target, actor, recent_session(actor))
      refute same.is_admin
    end
  end

  describe "삭제 — 잠금 방지" do
    test "성공과 거부 시도를 삭제 전 이메일의 마스킹된 구조화 이벤트로 남긴다" do
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

    test "최근 MFA가 없거나 만료되면 거부하고 최근 MFA 세션은 허용한다" do
      actor = admin_fixture()
      target = account_fixture()

      assert {:error, :recent_mfa_required} = Admin.delete_account(target, actor)

      assert {:error, :recent_mfa_required} =
               Admin.delete_account(target, actor, recent_session(actor, 601))

      assert {:ok, deleted} = Admin.delete_account(target, actor, recent_session(actor))
      assert deleted.deleted_at
    end

    test "다른 actor의 MFA 세션은 인정하지 않는다" do
      actor = admin_fixture()
      other = admin_fixture()
      target = account_fixture()

      assert {:error, :recent_mfa_required} =
               Admin.delete_account(target, actor, recent_session(other))

      refute VR.Repo.reload!(target).deleted_at
    end

    test "폐기된 세션의 MFA 기록은 인정하지 않는다" do
      actor = admin_fixture()
      target = account_fixture()
      session = recent_session(actor)
      {:ok, revoked} = session |> Ecto.Changeset.change(%{is_active: false}) |> VR.Repo.update()

      assert {:error, :recent_mfa_required} = Admin.delete_account(target, actor, revoked)
      refute VR.Repo.reload!(target).deleted_at
    end

    test "일반 사용자가 직접 호출하면 거부한다" do
      actor = account_fixture()
      target = account_fixture()

      assert {:error, :unauthorized} = Admin.delete_account(target, actor)
      refute VR.Repo.reload!(target).deleted_at
    end

    test "자기 자신은 삭제할 수 없다" do
      actor = admin_fixture()

      assert {:error, :cannot_delete_self} =
               Admin.delete_account(actor, actor, recent_session(actor))
    end

    test "마지막 어드민은 삭제할 수 없다" do
      actor = admin_fixture()
      last = admin_fixture()

      session = recent_session(actor)
      {:ok, demoted} = Admin.demote(last, actor, session)
      assert {:ok, _} = Admin.delete_account(demoted, actor, session)

      assert {:error, :cannot_delete_self} = Admin.delete_account(actor, actor, session)
    end

    test "다른 어드민이 있으면 어드민도 삭제할 수 있다" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:ok, deleted} = Admin.delete_account(target, actor, recent_session(actor))
      assert deleted.deleted_at
      refute deleted.is_admin
    end

    test "삭제하면 이메일이 익명화된다" do
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

    test "삭제하면 세션과 친구 관계가 정리된다" do
      actor = admin_fixture()
      target = account_fixture()
      friend = account_fixture()

      {:ok, token, _} = Accounts.create_session(target)
      {:ok, _} = VR.Friends.create_friendship(target.id, friend.id)

      {:ok, _} = Admin.delete_account(target, actor, recent_session(actor))

      assert :error = Accounts.get_account_by_session_token(token)
      assert VR.Friends.list_friends(friend.id) == []
    end

    test "이미 삭제된 계정은 다시 삭제할 수 없다" do
      actor = admin_fixture()
      target = account_fixture()

      session = recent_session(actor)
      {:ok, deleted} = Admin.delete_account(target, actor, session)
      assert {:error, :already_deleted} = Admin.delete_account(deleted, actor, session)
    end
  end

  describe "부트스트랩 입구 닫기 (실사용 시나리오)" do
    test "실사용자를 승격한 뒤 임시 계정을 지울 수 있다" do
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

    test "승격 전에는 임시 계정을 지울 수 없다 (잠금 방지)" do
      {:ok, boot, _} = Admin.ensure_bootstrap_admin(email: "boot@test.local")

      assert {:error, :cannot_delete_self} =
               Admin.delete_account(boot, boot, recent_session(boot))

      assert Admin.count_admins() == 1
    end
  end

  describe "capabilities/2 — UI 버튼 판단" do
    test "마지막 어드민에게는 강등·삭제를 막는다" do
      only = admin_fixture()
      caps = Admin.capabilities(only, only)

      refute caps.can_demote
      refute caps.can_delete
      assert caps.is_self
      assert caps.is_last_admin
    end

    test "다른 어드민이 있으면 열린다" do
      actor = admin_fixture()
      target = admin_fixture()
      caps = Admin.capabilities(target, actor)

      assert caps.can_demote
      assert caps.can_delete
      refute caps.is_self
    end

    test "일반 계정은 승격할 수 있다" do
      actor = admin_fixture()
      target = account_fixture()
      caps = Admin.capabilities(target, actor)

      assert caps.can_promote
      refute caps.can_demote
      assert caps.can_delete
    end
  end

  describe "목록" do
    test "검색과 필터가 동작한다" do
      _actor = admin_fixture(email: "admin@test.local", name: "관리자")
      _user = account_fixture(email: "someone@test.local", name: "홍길동")

      assert length(Admin.list_accounts()) == 2
      assert [%{email: "admin@test.local"}] = Admin.list_accounts(only: :admins)
      assert [%{name: "홍길동"}] = Admin.list_accounts(q: "홍길")
      assert [%{email: "admin@test.local"}] = Admin.list_accounts(q: "admin@")
    end

    test "삭제된 계정은 기본으로 숨긴다" do
      actor = admin_fixture()
      target = account_fixture()
      {:ok, _} = Admin.delete_account(target, actor, recent_session(actor))

      assert length(Admin.list_accounts()) == 1
      assert length(Admin.list_accounts(only: :deleted)) == 1
    end
  end
end
