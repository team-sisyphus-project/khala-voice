defmodule VR.AccountsTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts
  alias VR.Accounts.Account

  describe "register_account/1" do
    test "이메일과 비밀번호가 필요하다" do
      {:error, changeset} = Accounts.register_account(%{})
      assert %{email: ["can't be blank"], password: ["can't be blank"]} = errors_on(changeset)
    end

    test "짧은 비밀번호를 거부한다" do
      {:error, changeset} =
        Accounts.register_account(%{email: unique_email(), password: "short"})

      assert "10자 이상이어야 합니다" in errors_on(changeset).password
    end

    test "잘못된 이메일 형식을 거부한다" do
      {:error, changeset} =
        Accounts.register_account(%{email: "not-an-email", password: valid_password()})

      assert "이메일 형식이 올바르지 않습니다" in errors_on(changeset).email
    end

    test "중복 이메일을 거부한다" do
      account = account_fixture()

      {:error, changeset} =
        Accounts.register_account(%{email: account.email, password: valid_password()})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "대소문자가 달라도 같은 이메일로 본다" do
      account = account_fixture()

      {:error, changeset} =
        Accounts.register_account(%{
          email: String.upcase(account.email),
          password: valid_password()
        })

      assert "has already been taken" in errors_on(changeset).email
    end

    test "접두사가 붙은 ID를 만든다" do
      account = account_fixture()
      assert String.starts_with?(account.id, "acct_")
      assert VR.IdGenerator.valid?(account.id, :account)
    end

    test "locale 을 주지 않으면 영어로 가입한다" do
      account = account_fixture()
      assert account.locale == "en"
    end

    test "가입할 때 locale 을 지정할 수 있다" do
      {:ok, account} =
        Accounts.register_account(%{
          email: unique_email(),
          password: valid_password(),
          locale: "ko"
        })

      assert account.locale == "ko"
    end

    test "비밀번호를 평문으로 저장하지 않는다" do
      account = account_fixture()
      assert is_nil(account.password)
      assert account.hashed_password
      refute account.hashed_password == valid_password()

      %{rows: [[stored]]} =
        VR.Repo.query!("SELECT hashed_password FROM accounts WHERE id = $1", [account.id])

      refute String.contains?(stored, valid_password())
    end
  end

  describe "get_account_by_email_and_password/2" do
    test "올바른 비밀번호면 계정을 준다" do
      account = account_fixture()

      assert %Account{id: id} =
               Accounts.get_account_by_email_and_password(account.email, valid_password())

      assert id == account.id
    end

    test "틀린 비밀번호면 nil" do
      account = account_fixture()
      refute Accounts.get_account_by_email_and_password(account.email, "wrong-password-here")
    end

    test "없는 계정이면 nil" do
      refute Accounts.get_account_by_email_and_password("nobody@example.test", valid_password())
    end
  end

  describe "세션" do
    setup do
      %{account: account_fixture()}
    end

    test "토큰으로 계정을 찾는다", %{account: account} do
      {:ok, token, _session} = Accounts.create_session(account)
      assert {:ok, found, _} = Accounts.get_account_by_session_token(token)
      assert found.id == account.id
    end

    test "원본 토큰을 DB에 저장하지 않는다", %{account: account} do
      {:ok, token, session} = Accounts.create_session(account)

      %{rows: [[stored]]} =
        VR.Repo.query!("SELECT token_hash FROM account_sessions WHERE id = $1", [session.id])

      refute stored == token
      assert stored == :crypto.hash(:sha256, Base.url_decode64!(token, padding: false))
    end

    test "잘못된 토큰은 거부한다" do
      assert :error = Accounts.get_account_by_session_token("garbage")
      assert :error = Accounts.get_account_by_session_token(nil)
    end

    test "로그아웃하면 토큰이 무효화된다", %{account: account} do
      {:ok, token, _} = Accounts.create_session(account)
      :ok = Accounts.revoke_session(token)
      assert :error = Accounts.get_account_by_session_token(token)
    end

    test "기기 목록을 보여준다", %{account: account} do
      {:ok, _, _} = Accounts.create_session(account, %{user_agent: "Chrome"})
      {:ok, _, _} = Accounts.create_session(account, %{user_agent: "Safari"})
      assert length(Accounts.list_sessions(account.id)) == 2
    end

    test "특정 기기만 끊을 수 있다", %{account: account} do
      {:ok, keep_token, _} = Accounts.create_session(account)
      {:ok, kill_token, kill_session} = Accounts.create_session(account)

      :ok = Accounts.revoke_session_by_id(account.id, kill_session.id)

      assert {:ok, _, _} = Accounts.get_account_by_session_token(keep_token)
      assert :error = Accounts.get_account_by_session_token(kill_token)
    end
  end

  describe "update_password/3" do
    setup do
      %{account: account_fixture()}
    end

    test "비밀번호를 바꾸면 다른 세션이 전부 끊긴다", %{account: account} do
      {:ok, current_token, current_session} = Accounts.create_session(account)
      {:ok, other_token, _} = Accounts.create_session(account)

      {:ok, _} =
        Accounts.update_password(
          account,
          %{password: "brand-new-password"},
          keep_session_id: current_session.id
        )

      assert {:ok, _, _} = Accounts.get_account_by_session_token(current_token)
      assert :error = Accounts.get_account_by_session_token(other_token)
    end

    test "새 비밀번호로 로그인된다", %{account: account} do
      {:ok, _} = Accounts.update_password(account, %{password: "brand-new-password"})

      assert Accounts.get_account_by_email_and_password(account.email, "brand-new-password")
      refute Accounts.get_account_by_email_and_password(account.email, valid_password())
    end
  end

  describe "이메일 토큰" do
    setup do
      %{account: account_fixture()}
    end

    test "확인 토큰으로 계정을 확인한다", %{account: account} do
      refute account.confirmed_at
      {:ok, token} = Accounts.create_email_token(account, "confirm")
      assert {:ok, confirmed} = Accounts.confirm_account(token)
      assert confirmed.confirmed_at
    end

    test "같은 토큰을 두 번 쓸 수 없다", %{account: account} do
      {:ok, token} = Accounts.create_email_token(account, "confirm")
      assert {:ok, _} = Accounts.confirm_account(token)
      assert :error = Accounts.confirm_account(token)
    end

    test "컨텍스트가 다르면 통하지 않는다", %{account: account} do
      {:ok, token} = Accounts.create_email_token(account, "confirm")
      assert :error = Accounts.consume_email_token(token, "reset_password")
    end

    test "재설정 토큰으로 비밀번호를 바꾸면 모든 세션이 끊긴다", %{account: account} do
      {:ok, session_token, _} = Accounts.create_session(account)
      {:ok, reset_token} = Accounts.create_email_token(account, "reset_password")

      assert {:ok, _} = Accounts.reset_password(reset_token, %{password: "reset-password-value"})
      assert :error = Accounts.get_account_by_session_token(session_token)
      assert Accounts.get_account_by_email_and_password(account.email, "reset-password-value")
    end
  end

  describe "로그인 시도 제한" do
    test "실패가 쌓이면 잠근다" do
      email = unique_email()
      assert :ok = Accounts.login_allowed?(email, "1.2.3.4")

      for _ <- 1..10, do: Accounts.record_login_attempt(email, "1.2.3.4", false)

      assert {:error, :too_many_attempts} = Accounts.login_allowed?(email, "1.2.3.4")
    end

    test "다른 이메일은 영향받지 않는다" do
      blocked = unique_email()
      for _ <- 1..10, do: Accounts.record_login_attempt(blocked, "1.2.3.4", false)

      # 같은 IP지만 IP 한도(30)에는 아직 못 미친다
      assert :ok = Accounts.login_allowed?(unique_email(), "1.2.3.4")
    end

    test "성공하면 실패 기록이 지워진다" do
      email = unique_email()
      for _ <- 1..10, do: Accounts.record_login_attempt(email, "1.2.3.4", false)
      assert {:error, :too_many_attempts} = Accounts.login_allowed?(email, "1.2.3.4")

      :ok = Accounts.clear_failures(email)
      assert :ok = Accounts.login_allowed?(email, "1.2.3.4")
    end
  end

  describe "소셜 로그인" do
    test "새 소셜 계정을 만든다" do
      email = unique_email()

      assert {:ok, account} =
               Accounts.find_or_create_social_account("google", "google-uid-1", %{
                 email: email,
                 name: "소셜 사용자"
               })

      assert account.is_social
      assert account.social_provider == "google"
      # 제공자가 이미 이메일을 검증했다
      assert account.confirmed_at
    end

    test "같은 소셜 ID면 기존 계정을 준다" do
      {:ok, first} =
        Accounts.find_or_create_social_account("google", "uid-2", %{email: unique_email()})

      {:ok, second} =
        Accounts.find_or_create_social_account("google", "uid-2", %{email: unique_email()})

      assert first.id == second.id
    end

    test "이메일이 같으면 기존 비밀번호 계정에 연결한다" do
      existing = account_fixture()

      assert {:ok, linked} =
               Accounts.find_or_create_social_account("google", "uid-3", %{email: existing.email})

      assert linked.id == existing.id
      assert linked.social_provider == "google"
      # 기존 비밀번호는 그대로 남는다
      assert Accounts.get_account_by_email_and_password(existing.email, valid_password())
    end
  end

  describe "update_locale/2" do
    test "허용된 언어로 바꾼다" do
      account = account_fixture()
      {:ok, updated} = Accounts.update_locale(account, "ja")
      assert updated.locale == "ja"
    end

    test "지원하지 않는 언어를 거부한다" do
      account = account_fixture()
      {:error, changeset} = Accounts.update_locale(account, "fr")
      assert "is invalid" in errors_on(changeset).locale
    end

    test "빈 값을 거부한다" do
      account = account_fixture()
      {:error, changeset} = Accounts.update_locale(account, "")
      assert errors_on(changeset).locale != []
    end

    test "nil 을 거부한다" do
      account = account_fixture()
      {:error, changeset} = Accounts.update_locale(account, nil)
      assert "can't be blank" in errors_on(changeset).locale
    end

    test "다른 필드는 건드리지 않는다" do
      account = account_fixture(locale: "ko")
      {:ok, updated} = Accounts.update_locale(account, "en")
      assert updated.locale == "en"
      assert updated.transcribe_language == account.transcribe_language
      assert updated.theme == account.theme
    end
  end

  describe "삭제 예약" do
    test "예약하면 모든 세션이 끊긴다" do
      account = account_fixture()
      {:ok, token, _} = Accounts.create_session(account)

      {:ok, scheduled} = Accounts.schedule_deletion(account)

      assert scheduled.scheduled_deletion_at
      assert :error = Accounts.get_account_by_session_token(token)
    end

    test "취소할 수 있다" do
      account = account_fixture()
      {:ok, scheduled} = Accounts.schedule_deletion(account)
      {:ok, cancelled} = Accounts.cancel_deletion(scheduled)
      refute cancelled.scheduled_deletion_at
    end
  end
end
