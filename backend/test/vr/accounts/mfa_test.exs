defmodule VR.Accounts.MFATest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts.MFA

  setup do
    account = account_fixture()
    {:ok, admin} = account |> Ecto.Changeset.change(%{is_admin: true}) |> VR.Repo.update()
    %{admin: admin, secret: MFA.generate_secret()}
  end

  describe "dev-environment bypass" do
    test "the bypass is on in the test environment" do
      assert MFA.dev_bypass?()
    end

    test "any 6-digit number passes", %{secret: secret} do
      assert MFA.valid_code?(secret, "000000")
      assert MFA.valid_code?(secret, "123456")
      assert MFA.valid_code?(secret, "999999")
    end

    test "non-6-digit input does not pass", %{secret: secret} do
      refute MFA.valid_code?(secret, "12345")
      refute MFA.valid_code?(secret, "1234567")
      refute MFA.valid_code?(secret, "abcdef")
      refute MFA.valid_code?(secret, "")
    end

    test "a real TOTP code passes too, of course", %{secret: secret} do
      assert MFA.valid_code?(secret, NimbleTOTP.verification_code(secret))
    end
  end

  describe "enabling and disabling" do
    test "a correct code enables MFA and returns backup codes", %{admin: admin, secret: secret} do
      assert {:ok, updated, codes} = MFA.enable(admin, secret, "123456")

      assert updated.mfa_enabled
      assert updated.mfa_enabled_at
      assert length(codes) == 10
      assert MFA.backup_codes_left(updated) == 10
    end

    test "backup codes are not stored in plaintext", %{admin: admin, secret: secret} do
      {:ok, updated, codes} = MFA.enable(admin, secret, "123456")
      first = hd(codes)

      refute first in updated.mfa_backup_hashes
      assert Enum.all?(updated.mfa_backup_hashes, &(byte_size(&1) == 64))
    end

    test "the secret is not stored in plaintext", %{admin: admin, secret: secret} do
      {:ok, updated, _} = MFA.enable(admin, secret, "123456")

      %{rows: [[stored]]} =
        VR.Repo.query!("SELECT mfa_secret_encrypted FROM accounts WHERE id = $1", [updated.id])

      refute stored == secret
      assert String.contains?(stored, "AES.GCM.V1")
    end

    test "a wrong code does not enable MFA", %{admin: admin, secret: secret} do
      assert {:error, :invalid_code} = MFA.enable(admin, secret, "not-a-code")
    end

    test "can be disabled", %{admin: admin, secret: secret} do
      {:ok, enabled, _} = MFA.enable(admin, secret, "123456")
      assert {:ok, disabled} = MFA.disable(enabled, "123456")

      refute disabled.mfa_enabled
      assert is_nil(disabled.mfa_secret)
      assert disabled.mfa_backup_hashes == []
    end
  end

  describe "login verification" do
    test "accounts that never enrolled do not pass code verification", %{admin: admin} do
      # Login itself passes. Admin-screen entry is blocked separately by satisfied?/1.
      # **Accounts that have not enrolled must not pass.** This used to be :ok, but since
      # login always sends admins to the code screen, an admin without MFA could enter any
      # digits and get through — pretending to have 2FA while only the password protected them.
      assert {:error, :not_enrolled} = MFA.verify(admin, "anything")
    end

    test "admins are **subject to the mandate** even before enrolling", %{admin: admin} do
      # One breached admin account hands over the whole system's settings and keys.
      # "Not enrolled yet, so don't ask" means they never enroll.
      assert MFA.required?(admin)
      refute MFA.satisfied?(admin)
    end

    test "enabling satisfies the entry condition", %{admin: admin, secret: secret} do
      {:ok, enabled, _} = MFA.enable(admin, secret, "123456")

      assert MFA.required?(enabled)
      assert MFA.satisfied?(enabled)
    end

    test "not required of regular users" do
      # Asking people to install an authenticator app just to read meeting notes drives most of them away
      user = account_fixture()

      refute MFA.required?(user)
      assert MFA.satisfied?(user)
    end

    test "a backup code passes", %{admin: admin, secret: secret} do
      {:ok, enabled, codes} = MFA.enable(admin, secret, "123456")
      code = hd(codes)

      assert :ok = MFA.verify(enabled, code)
    end

    test "a backup code is consumed after one use", %{admin: admin, secret: secret} do
      {:ok, enabled, codes} = MFA.enable(admin, secret, "123456")
      code = hd(codes)

      assert :ok = MFA.verify(enabled, code)

      reloaded = VR.Repo.get!(VR.Accounts.Account, enabled.id)
      assert MFA.backup_codes_left(reloaded) == 9
      assert {:error, :invalid_code} = MFA.verify(reloaded, code)
    end

    test "backup codes ignore case and hyphens", %{admin: admin, secret: secret} do
      {:ok, enabled, codes} = MFA.enable(admin, secret, "123456")
      code = hd(codes)

      messy = code |> String.downcase() |> String.replace("-", " ")
      assert :ok = MFA.verify(enabled, messy)
    end

    test "rejects an unknown code", %{admin: admin, secret: secret} do
      {:ok, enabled, _} = MFA.enable(admin, secret, "123456")
      assert {:error, :invalid_code} = MFA.verify(enabled, "ZZZZZ-ZZZZZ")
    end
  end

  describe "provisioning" do
    test "builds an otpauth URI", %{admin: admin, secret: secret} do
      uri = MFA.provisioning_uri(admin, secret)

      assert uri =~ "otpauth://totp/"
      assert uri =~ "KHALA%20VOICE"
      # The email goes into the path segment, so the @ survives as-is
      assert uri =~ admin.email
      assert uri =~ "secret="
    end

    test "returns a human-readable secret", %{secret: secret} do
      readable = MFA.readable_secret(secret)
      assert readable =~ ~r/^[A-Z2-7 ]+$/
      assert String.contains?(readable, " ")
    end
  end
end
