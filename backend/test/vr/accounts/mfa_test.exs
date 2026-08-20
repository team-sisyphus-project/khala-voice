defmodule VR.Accounts.MFATest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Accounts.MFA

  setup do
    account = account_fixture()
    {:ok, admin} = account |> Ecto.Changeset.change(%{is_admin: true}) |> VR.Repo.update()
    %{admin: admin, secret: MFA.generate_secret()}
  end

  describe "개발 환경 우회" do
    test "테스트 환경에서는 우회가 켜져 있다" do
      assert MFA.dev_bypass?()
    end

    test "6자리 숫자 아무거나 통과한다", %{secret: secret} do
      assert MFA.valid_code?(secret, "000000")
      assert MFA.valid_code?(secret, "123456")
      assert MFA.valid_code?(secret, "999999")
    end

    test "6자리 숫자가 아니면 통과하지 않는다", %{secret: secret} do
      refute MFA.valid_code?(secret, "12345")
      refute MFA.valid_code?(secret, "1234567")
      refute MFA.valid_code?(secret, "abcdef")
      refute MFA.valid_code?(secret, "")
    end

    test "실제 TOTP 코드도 당연히 통과한다", %{secret: secret} do
      assert MFA.valid_code?(secret, NimbleTOTP.verification_code(secret))
    end
  end

  describe "켜기 · 끄기" do
    test "코드가 맞으면 켜지고 백업 코드를 준다", %{admin: admin, secret: secret} do
      assert {:ok, updated, codes} = MFA.enable(admin, secret, "123456")

      assert updated.mfa_enabled
      assert updated.mfa_enabled_at
      assert length(codes) == 10
      assert MFA.backup_codes_left(updated) == 10
    end

    test "백업 코드를 평문으로 저장하지 않는다", %{admin: admin, secret: secret} do
      {:ok, updated, codes} = MFA.enable(admin, secret, "123456")
      first = hd(codes)

      refute first in updated.mfa_backup_hashes
      assert Enum.all?(updated.mfa_backup_hashes, &(byte_size(&1) == 64))
    end

    test "비밀키를 평문으로 저장하지 않는다", %{admin: admin, secret: secret} do
      {:ok, updated, _} = MFA.enable(admin, secret, "123456")

      %{rows: [[stored]]} =
        VR.Repo.query!("SELECT mfa_secret_encrypted FROM accounts WHERE id = $1", [updated.id])

      refute stored == secret
      assert String.contains?(stored, "AES.GCM.V1")
    end

    test "코드가 틀리면 켜지지 않는다", %{admin: admin, secret: secret} do
      assert {:error, :invalid_code} = MFA.enable(admin, secret, "not-a-code")
    end

    test "끌 수 있다", %{admin: admin, secret: secret} do
      {:ok, enabled, _} = MFA.enable(admin, secret, "123456")
      assert {:ok, disabled} = MFA.disable(enabled, "123456")

      refute disabled.mfa_enabled
      assert is_nil(disabled.mfa_secret)
      assert disabled.mfa_backup_hashes == []
    end
  end

  describe "로그인 검증" do
    test "아직 안 켠 계정은 코드 검증을 건너뛴다", %{admin: admin} do
      # 로그인 자체는 통과한다. 어드민 화면 진입은 satisfied?/1 이 따로 막는다.
      # **켜지 않은 계정은 통과시키지 않는다.** 예전에는 :ok 였는데, 로그인이
      # 어드민을 무조건 코드 화면으로 보내므로 MFA 를 안 켠 어드민이 아무 숫자나
      # 넣어도 통과했다 — 2단계 인증이 있는 척하면서 비밀번호 하나만 지켰다.
      assert {:error, :not_enrolled} = MFA.verify(admin, "아무거나")
    end

    test "어드민은 켜기 전에도 **의무 대상**이다", %{admin: admin} do
      # 어드민 계정 하나가 뚫리면 전체 시스템의 설정과 키가 함께 넘어간다.
      # "아직 안 켰으니 안 물어본다" 로 두면 영영 안 켠다.
      assert MFA.required?(admin)
      refute MFA.satisfied?(admin)
    end

    test "켜면 진입 조건을 만족한다", %{admin: admin, secret: secret} do
      {:ok, enabled, _} = MFA.enable(admin, secret, "123456")

      assert MFA.required?(enabled)
      assert MFA.satisfied?(enabled)
    end

    test "일반 사용자에게는 요구하지 않는다" do
      # 회의록을 보려고 인증기 앱을 깔라고 하면 대부분 떠난다
      user = account_fixture()

      refute MFA.required?(user)
      assert MFA.satisfied?(user)
    end

    test "백업 코드로 통과할 수 있다", %{admin: admin, secret: secret} do
      {:ok, enabled, codes} = MFA.enable(admin, secret, "123456")
      code = hd(codes)

      assert :ok = MFA.verify(enabled, code)
    end

    test "백업 코드는 한 번 쓰면 소진된다", %{admin: admin, secret: secret} do
      {:ok, enabled, codes} = MFA.enable(admin, secret, "123456")
      code = hd(codes)

      assert :ok = MFA.verify(enabled, code)

      reloaded = VR.Repo.get!(VR.Accounts.Account, enabled.id)
      assert MFA.backup_codes_left(reloaded) == 9
      assert {:error, :invalid_code} = MFA.verify(reloaded, code)
    end

    test "백업 코드는 대소문자·하이픈을 무시한다", %{admin: admin, secret: secret} do
      {:ok, enabled, codes} = MFA.enable(admin, secret, "123456")
      code = hd(codes)

      messy = code |> String.downcase() |> String.replace("-", " ")
      assert :ok = MFA.verify(enabled, messy)
    end

    test "모르는 코드는 거부한다", %{admin: admin, secret: secret} do
      {:ok, enabled, _} = MFA.enable(admin, secret, "123456")
      assert {:error, :invalid_code} = MFA.verify(enabled, "ZZZZZ-ZZZZZ")
    end
  end

  describe "프로비저닝" do
    test "otpauth URI 를 만든다", %{admin: admin, secret: secret} do
      uri = MFA.provisioning_uri(admin, secret)

      assert uri =~ "otpauth://totp/"
      assert uri =~ "KHALA%20VOICE"
      # 이메일은 경로 구간에 들어가 @ 가 그대로 남는다
      assert uri =~ admin.email
      assert uri =~ "secret="
    end

    test "사람이 읽을 수 있는 비밀키를 준다", %{secret: secret} do
      readable = MFA.readable_secret(secret)
      assert readable =~ ~r/^[A-Z2-7 ]+$/
      assert String.contains?(readable, " ")
    end
  end
end
