defmodule VR.Accounts.AdminTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts
  alias VR.Accounts.Admin

  defp admin_fixture(attrs \\ %{}) do
    account = account_fixture(attrs)
    {:ok, updated} = account |> Ecto.Changeset.change(%{is_admin: true}) |> VR.Repo.update()
    updated
  end

  describe "부트스트랩" do
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
    test "일반 사용자가 직접 호출하면 거부한다" do
      actor = account_fixture()
      target = account_fixture()

      assert {:error, :unauthorized} = Admin.promote(target, actor)
      refute VR.Repo.reload!(target).is_admin
    end

    test "일반 계정을 어드민으로 만든다" do
      actor = admin_fixture()
      target = account_fixture()

      assert {:ok, promoted} = Admin.promote(target, actor)
      assert promoted.is_admin
      assert Admin.count_admins() == 2
    end

    test "이미 어드민이면 그대로 둔다" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:ok, same} = Admin.promote(target, actor)
      assert same.is_admin
    end

    test "삭제된 계정은 승격할 수 없다" do
      actor = admin_fixture()
      target = account_fixture()
      {:ok, deleted} = Admin.delete_account(target, actor)

      assert {:error, :account_deleted} = Admin.promote(deleted, actor)
    end
  end

  describe "강등 — 잠금 방지" do
    test "일반 사용자가 직접 호출하면 거부한다" do
      actor = account_fixture()
      target = admin_fixture()

      assert {:error, :unauthorized} = Admin.demote(target, actor)
      assert VR.Repo.reload!(target).is_admin
    end

    test "마지막 어드민은 강등할 수 없다" do
      only_admin = admin_fixture()
      other = admin_fixture()

      assert {:ok, _} = Admin.demote(other, only_admin)
      assert Admin.count_admins() == 1

      # 자기 자신이면서 마지막 어드민이다. 두 조건 모두 걸리는데
      # 더 구체적인 self 검사가 먼저 잡는다 — 사용자에게 더 알아듣기 쉬운 메시지다.
      assert {:error, :cannot_demote_self} = Admin.demote(only_admin, only_admin)
      assert Admin.count_admins() == 1

      # 다른 어드민이 마지막 하나를 강등하려 하면 last_admin 으로 막힌다
      third = account_fixture()
      {:ok, third_admin} = Admin.promote(third, only_admin)
      {:ok, _} = Admin.demote(only_admin, third_admin)
      assert Admin.count_admins() == 1
      assert {:error, :cannot_demote_self} = Admin.demote(third_admin, third_admin)
    end

    test "자기 자신은 강등할 수 없다" do
      actor = admin_fixture()
      _other = admin_fixture()

      assert {:error, :cannot_demote_self} = Admin.demote(actor, actor)
    end

    test "다른 어드민은 강등할 수 있다" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:ok, demoted} = Admin.demote(target, actor)
      refute demoted.is_admin
    end

    test "어드민이 아니면 아무 일도 없다" do
      actor = admin_fixture()
      target = account_fixture()

      assert {:ok, same} = Admin.demote(target, actor)
      refute same.is_admin
    end
  end

  describe "삭제 — 잠금 방지" do
    test "일반 사용자가 직접 호출하면 거부한다" do
      actor = account_fixture()
      target = account_fixture()

      assert {:error, :unauthorized} = Admin.delete_account(target, actor)
      refute VR.Repo.reload!(target).deleted_at
    end

    test "자기 자신은 삭제할 수 없다" do
      actor = admin_fixture()
      assert {:error, :cannot_delete_self} = Admin.delete_account(actor, actor)
    end

    test "마지막 어드민은 삭제할 수 없다" do
      actor = admin_fixture()
      last = admin_fixture()

      {:ok, demoted} = Admin.demote(last, actor)
      assert {:ok, _} = Admin.delete_account(demoted, actor)

      assert {:error, :cannot_delete_self} = Admin.delete_account(actor, actor)
    end

    test "다른 어드민이 있으면 어드민도 삭제할 수 있다" do
      actor = admin_fixture()
      target = admin_fixture()

      assert {:ok, deleted} = Admin.delete_account(target, actor)
      assert deleted.deleted_at
      refute deleted.is_admin
    end

    test "삭제하면 이메일이 익명화된다" do
      actor = admin_fixture()
      target = account_fixture(email: "victim@test.local")

      {:ok, deleted} = Admin.delete_account(target, actor)

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

      {:ok, _} = Admin.delete_account(target, actor)

      assert :error = Accounts.get_account_by_session_token(token)
      assert VR.Friends.list_friends(friend.id) == []
    end

    test "이미 삭제된 계정은 다시 삭제할 수 없다" do
      actor = admin_fixture()
      target = account_fixture()

      {:ok, deleted} = Admin.delete_account(target, actor)
      assert {:error, :already_deleted} = Admin.delete_account(deleted, actor)
    end
  end

  describe "부트스트랩 입구 닫기 (실사용 시나리오)" do
    test "실사용자를 승격한 뒤 임시 계정을 지울 수 있다" do
      {:ok, boot, _password} = Admin.ensure_bootstrap_admin(email: "boot@test.local")
      assert Admin.count_admins() == 1
      assert Admin.bootstrap_account()

      real = account_fixture(email: "real@test.local")

      {:ok, real_admin} = Admin.promote(real, boot)
      assert Admin.count_admins() == 2

      assert {:ok, _} = Admin.delete_account(boot, real_admin)
      assert Admin.count_admins() == 1
      assert is_nil(Admin.bootstrap_account())

      refute Accounts.get_account_by_email("boot@test.local")
    end

    test "승격 전에는 임시 계정을 지울 수 없다 (잠금 방지)" do
      {:ok, boot, _} = Admin.ensure_bootstrap_admin(email: "boot@test.local")

      assert {:error, :cannot_delete_self} = Admin.delete_account(boot, boot)
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
      {:ok, _} = Admin.delete_account(target, actor)

      assert length(Admin.list_accounts()) == 1
      assert length(Admin.list_accounts(only: :deleted)) == 1
    end
  end
end
