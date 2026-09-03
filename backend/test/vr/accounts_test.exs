defmodule VR.AccountsTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts
  alias VR.Accounts.Account

  describe "register_account/1" do
    test "requires email and password" do
      {:error, changeset} = Accounts.register_account(%{})
      assert %{email: ["can't be blank"], password: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a short password" do
      {:error, changeset} =
        Accounts.register_account(%{email: unique_email(), password: "short"})

      assert "must be at least 10 characters" in errors_on(changeset).password
    end

    test "rejects a malformed email" do
      {:error, changeset} =
        Accounts.register_account(%{email: "not-an-email", password: valid_password()})

      assert "is not a valid email address" in errors_on(changeset).email
    end

    test "rejects a duplicate email" do
      account = account_fixture()

      {:error, changeset} =
        Accounts.register_account(%{email: account.email, password: valid_password()})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "treats emails as the same regardless of case" do
      account = account_fixture()

      {:error, changeset} =
        Accounts.register_account(%{
          email: String.upcase(account.email),
          password: valid_password()
        })

      assert "has already been taken" in errors_on(changeset).email
    end

    test "generates prefixed IDs" do
      account = account_fixture()
      assert String.starts_with?(account.id, "acct_")
      assert VR.IdGenerator.valid?(account.id, :account)
    end

    test "signs up in English when no locale is given" do
      account = account_fixture()
      assert account.locale == "en"
    end

    test "locale can be specified at signup" do
      {:ok, account} =
        Accounts.register_account(%{
          email: unique_email(),
          password: valid_password(),
          locale: "ko"
        })

      assert account.locale == "ko"
    end

    test "new accounts default to the light theme" do
      assert account_fixture().theme == "light"
    end

    test "does not store the password in plaintext" do
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
    test "returns the account for a correct password" do
      account = account_fixture()

      assert %Account{id: id} =
               Accounts.get_account_by_email_and_password(account.email, valid_password())

      assert id == account.id
    end

    test "nil for a wrong password" do
      account = account_fixture()
      refute Accounts.get_account_by_email_and_password(account.email, "wrong-password-here")
    end

    test "nil for a nonexistent account" do
      refute Accounts.get_account_by_email_and_password("nobody@example.test", valid_password())
    end
  end

  describe "sessions" do
    setup do
      %{account: account_fixture()}
    end

    test "finds the account by token", %{account: account} do
      {:ok, token, _session} = Accounts.create_session(account)
      assert {:ok, found, _} = Accounts.get_account_by_session_token(token)
      assert found.id == account.id
    end

    test "the raw token is not stored in the DB", %{account: account} do
      {:ok, token, session} = Accounts.create_session(account)

      %{rows: [[stored]]} =
        VR.Repo.query!("SELECT token_hash FROM account_sessions WHERE id = $1", [session.id])

      refute stored == token
      assert stored == :crypto.hash(:sha256, Base.url_decode64!(token, padding: false))
    end

    test "rejects an invalid token" do
      assert :error = Accounts.get_account_by_session_token("garbage")
      assert :error = Accounts.get_account_by_session_token(nil)
    end

    test "logging out invalidates the token", %{account: account} do
      {:ok, token, _} = Accounts.create_session(account)
      :ok = Accounts.revoke_session(token)
      assert :error = Accounts.get_account_by_session_token(token)
    end

    test "lists devices", %{account: account} do
      {:ok, _, _} = Accounts.create_session(account, %{user_agent: "Chrome"})
      {:ok, _, _} = Accounts.create_session(account, %{user_agent: "Safari"})
      assert length(Accounts.list_sessions(account.id)) == 2
    end

    test "a single device can be disconnected", %{account: account} do
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

    test "changing the password revokes all other sessions", %{account: account} do
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

    test "the new password logs in", %{account: account} do
      {:ok, _} = Accounts.update_password(account, %{password: "brand-new-password"})

      assert Accounts.get_account_by_email_and_password(account.email, "brand-new-password")
      refute Accounts.get_account_by_email_and_password(account.email, valid_password())
    end
  end

  describe "email tokens" do
    setup do
      %{account: account_fixture()}
    end

    test "confirms the account with a confirmation token", %{account: account} do
      refute account.confirmed_at
      {:ok, token} = Accounts.create_email_token(account, "confirm")
      assert {:ok, confirmed} = Accounts.confirm_account(token)
      assert confirmed.confirmed_at
    end

    test "the same token cannot be used twice", %{account: account} do
      {:ok, token} = Accounts.create_email_token(account, "confirm")
      assert {:ok, _} = Accounts.confirm_account(token)
      assert :error = Accounts.confirm_account(token)
    end

    test "a different context does not pass", %{account: account} do
      {:ok, token} = Accounts.create_email_token(account, "confirm")
      assert :error = Accounts.consume_email_token(token, "reset_password")
    end

    test "resetting the password via token revokes all sessions", %{account: account} do
      {:ok, session_token, _} = Accounts.create_session(account)
      {:ok, reset_token} = Accounts.create_email_token(account, "reset_password")

      assert {:ok, _} = Accounts.reset_password(reset_token, %{password: "reset-password-value"})
      assert :error = Accounts.get_account_by_session_token(session_token)
      assert Accounts.get_account_by_email_and_password(account.email, "reset-password-value")
    end
  end

  describe "login attempt limiting" do
    test "locks after accumulated failures" do
      email = unique_email()
      assert :ok = Accounts.login_allowed?(email, "1.2.3.4")

      for _ <- 1..10, do: Accounts.record_login_attempt(email, "1.2.3.4", false)

      assert {:error, :too_many_attempts} = Accounts.login_allowed?(email, "1.2.3.4")
    end

    test "other emails are unaffected" do
      blocked = unique_email()
      for _ <- 1..10, do: Accounts.record_login_attempt(blocked, "1.2.3.4", false)

      # Same IP, but still below the IP limit (30)
      assert :ok = Accounts.login_allowed?(unique_email(), "1.2.3.4")
    end

    test "success clears the failure record" do
      email = unique_email()
      for _ <- 1..10, do: Accounts.record_login_attempt(email, "1.2.3.4", false)
      assert {:error, :too_many_attempts} = Accounts.login_allowed?(email, "1.2.3.4")

      :ok = Accounts.clear_failures(email)
      assert :ok = Accounts.login_allowed?(email, "1.2.3.4")
    end
  end

  describe "social login" do
    test "creates a new social account" do
      email = unique_email()

      assert {:ok, account} =
               Accounts.find_or_create_social_account("google", "google-uid-1", %{
                 email: email,
                 name: "Social User"
               })

      assert account.is_social
      assert account.social_provider == "google"
      # The provider already verified the email
      assert account.confirmed_at
    end

    test "returns the existing account for the same social ID" do
      {:ok, first} =
        Accounts.find_or_create_social_account("google", "uid-2", %{email: unique_email()})

      {:ok, second} =
        Accounts.find_or_create_social_account("google", "uid-2", %{email: unique_email()})

      assert first.id == second.id
    end

    test "links to the existing password account when the email matches" do
      existing = account_fixture()

      assert {:ok, linked} =
               Accounts.find_or_create_social_account("google", "uid-3", %{email: existing.email})

      assert linked.id == existing.id
      assert linked.social_provider == "google"
      # The existing password stays intact
      assert Accounts.get_account_by_email_and_password(existing.email, valid_password())
    end
  end

  describe "update_locale/2" do
    test "changes to an allowed language" do
      account = account_fixture()
      {:ok, updated} = Accounts.update_locale(account, "ja")
      assert updated.locale == "ja"
    end

    test "rejects an unsupported language" do
      account = account_fixture()
      {:error, changeset} = Accounts.update_locale(account, "fr")
      assert "is invalid" in errors_on(changeset).locale
    end

    test "rejects an empty value" do
      account = account_fixture()
      {:error, changeset} = Accounts.update_locale(account, "")
      assert errors_on(changeset).locale != []
    end

    test "rejects nil" do
      account = account_fixture()
      {:error, changeset} = Accounts.update_locale(account, nil)
      assert "can't be blank" in errors_on(changeset).locale
    end

    test "does not touch other fields" do
      account = account_fixture(locale: "ko")
      {:ok, updated} = Accounts.update_locale(account, "en")
      assert updated.locale == "en"
      assert updated.transcribe_language == account.transcribe_language
      assert updated.theme == account.theme
    end
  end

  describe "scheduled deletion" do
    test "scheduling revokes all sessions" do
      account = account_fixture()
      {:ok, token, _} = Accounts.create_session(account)

      {:ok, scheduled} = Accounts.schedule_deletion(account)

      assert scheduled.scheduled_deletion_at
      assert :error = Accounts.get_account_by_session_token(token)
    end

    test "can be cancelled" do
      account = account_fixture()
      {:ok, scheduled} = Accounts.schedule_deletion(account)
      {:ok, cancelled} = Accounts.cancel_deletion(scheduled)
      refute cancelled.scheduled_deletion_at
    end
  end
end
