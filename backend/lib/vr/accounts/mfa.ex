defmodule VR.Accounts.MFA do
  @moduledoc """
  시스템 어드민 2단계 인증 (TOTP).

  ## 왜 어드민에게만인가

  시스템 어드민은 **전체 시스템의 운영자**다. 모든 계정을 지우고 API 키를 읽고
  다른 사람을 어드민으로 만들 수 있다. 계정 하나가 뚫렸을 때의 피해 범위가
  일반 사용자와 다르다. 그래서 여기만 2단계를 건다.

  일반 사용자에게는 MFA 를 노출하지 않는다 — 쓸 일이 없는 설정이 늘면
  그 자체가 이탈 요인이다.

  ## 개발 환경 우회

  **운영이 아닌 곳에서는 6자리 숫자 아무거나 통과한다.**

  개발·테스트에서 실제 인증기 앱을 붙여야 한다면 아무도 MFA 를 켜지 않게 되고,
  결국 운영에서 처음 켜보게 된다. 그게 더 위험하다.

  운영에서는 이 우회가 **동작하지 않는다** — `config_env() == :prod` 를 컴파일
  시점에 확인하므로 환경변수를 바꿔서 열 수 없다.
  """

  alias VR.Accounts.Account
  alias VR.Repo

  require Logger

  @issuer "KHALA VOICE"
  @backup_code_count 10

  # 컴파일 시점에 굳힌다. 런타임 환경변수로 우회할 수 없다.
  @dev_bypass Mix.env() != :prod

  @doc "이 환경에서 개발용 우회가 켜져 있는가. 화면에 경고를 띄우는 데 쓴다."
  def dev_bypass?, do: @dev_bypass

  @doc "새 TOTP 비밀키. 아직 저장하지 않는다 — 검증에 성공해야 켠다."
  def generate_secret, do: NimbleTOTP.secret()

  @doc """
  인증기 앱에 넣을 `otpauth://` URI.

  QR 로 보여주고, 스캔이 안 되는 환경을 위해 비밀키도 함께 노출한다.
  """
  def provisioning_uri(%Account{email: email}, secret) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{email}", secret, issuer: @issuer)
  end

  @doc "비밀키를 사람이 옮겨적을 수 있는 형태로."
  def readable_secret(secret) do
    secret
    |> Base.encode32(padding: false)
    |> String.replace(~r/(.{4})(?=.)/, "\\1 ")
  end

  @doc """
  코드를 검증한다.

  운영이 아니면 6자리 숫자 아무거나 통과한다 (`dev_bypass?/0`).
  """
  def valid_code?(secret, code) when is_binary(code) do
    normalized = String.replace(code, ~r/\s/, "")

    cond do
      @dev_bypass and normalized =~ ~r/^\d{6}$/ ->
        Logger.warning("[MFA] 개발용 우회로 통과했습니다. 운영에서는 동작하지 않습니다.")
        true

      is_nil(secret) ->
        false

      true ->
        # 시계 오차를 감안해 앞뒤 한 구간을 허용한다
        NimbleTOTP.valid?(secret, normalized, since: nil)
    end
  end

  def valid_code?(_secret, _code), do: false

  @doc """
  MFA 를 켠다. 코드 검증에 성공해야 켜진다.

  `{:ok, account, backup_codes}` — 백업 코드는 **이때 한 번만** 볼 수 있다.
  해시로만 저장한다.
  """
  def enable(%Account{} = account, secret, code) do
    # 개발 환경 우회는 `valid_code?/2` 안에 이미 있다 (6자리 숫자 아무거나).
    # 여기서 한 번 더 열어 주면 **아무 문자열이나** 통과해 "코드가 틀리면 켜지지
    # 않는다"가 무너진다.
    if valid_code?(secret, code) do
      codes = Enum.map(1..@backup_code_count, fn _ -> generate_backup_code() end)
      hashes = Enum.map(codes, &hash_backup_code/1)

      result =
        account
        |> Account.mfa_changeset(%{
          mfa_secret: secret,
          mfa_enabled: true,
          mfa_enabled_at: DateTime.utc_now(:second),
          mfa_backup_hashes: hashes
        })
        |> Repo.update()

      with {:ok, updated} <- result, do: {:ok, updated, codes}
    else
      {:error, :invalid_code}
    end
  end

  @doc "MFA 를 끈다. 현재 코드를 확인한 뒤에만 끈다."
  def disable(%Account{} = account, code) do
    if verify(account, code) == :ok do
      account
      |> Account.mfa_changeset(%{
        mfa_secret: nil,
        mfa_enabled: false,
        mfa_enabled_at: nil,
        mfa_backup_hashes: []
      })
      |> Repo.update()
    else
      {:error, :invalid_code}
    end
  end

  @doc """
  로그인 시 코드를 확인한다. TOTP 또는 백업 코드를 받는다.

  백업 코드는 **한 번 쓰면 소진된다.**
  """
  # **켜지 않은 계정은 통과시키지 않는다.**
  #
  # 예전에는 여기서 `:ok` 를 돌려줬다. 그런데 로그인은 어드민을 **무조건**
  # 코드 화면으로 보내므로, MFA 를 켜지 않은 어드민은 아무 숫자나 넣어도
  # 통과했다 — 2단계 인증이 있는 척하면서 실제로는 비밀번호 하나만 지키고 있었다.
  #
  # 켜지 않은 계정은 코드를 확인할 수단이 없다. 확인할 수 없으면 통과가 아니라
  # 거절이다. 그 계정은 코드 화면이 아니라 **등록 화면**으로 가야 한다
  # (`SessionController.enroll/2`).
  def verify(%Account{mfa_enabled: false}, _code), do: {:error, :not_enrolled}

  def verify(%Account{} = account, code) when is_binary(code) do
    cond do
      valid_code?(account.mfa_secret, code) -> :ok
      true -> consume_backup_code(account, code)
    end
  end

  def verify(_account, _code), do: {:error, :invalid_code}

  @doc """
  이 계정에 2단계 인증이 **의무인가.**

  **시스템 어드민은 예외 없이 의무다.** 어드민 계정 하나가 뚫리면 전체 시스템의
  설정 · API 키 · 모든 계정이 함께 넘어간다. 비밀번호 하나로 그것을 지킬 수 없다.

  일반 사용자에게는 요구하지 않는다 — 회의록을 보려고 인증기 앱을 깔라고
  하면 대부분 떠난다.

  `mfa_enabled` 와는 다른 질문이다. 아직 켜지 않은 어드민도 **의무 대상**이고,
  그래서 어드민 화면에 들어가기 전에 설정을 강제한다.
  """
  def required?(%Account{is_admin: true}), do: true
  def required?(_account), do: false

  @doc "지금 어드민 화면에 들어갈 수 있는가. 의무인데 아직 안 켰으면 막는다."
  def satisfied?(%Account{} = account) do
    not required?(account) or account.mfa_enabled
  end

  @doc "남은 백업 코드 수."
  def backup_codes_left(%Account{mfa_backup_hashes: hashes}), do: length(hashes)

  # ── 백업 코드 ────────────────────────────────────────────

  # 사람이 옮겨적기 쉽도록 헷갈리는 글자를 뺀다
  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  defp generate_backup_code do
    1..10
    |> Enum.map(fn _ -> Enum.random(@alphabet) end)
    |> List.to_string()
    |> String.replace(~r/(.{5})(?=.)/, "\\1-")
  end

  defp hash_backup_code(code) do
    :sha256
    |> :crypto.hash(normalize_backup_code(code))
    |> Base.encode16(case: :lower)
  end

  defp normalize_backup_code(code) do
    code |> to_string() |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")
  end

  defp consume_backup_code(%Account{} = account, code) do
    hash = hash_backup_code(code)

    if hash in account.mfa_backup_hashes do
      remaining = List.delete(account.mfa_backup_hashes, hash)

      account
      |> Account.mfa_changeset(%{mfa_backup_hashes: remaining})
      |> Repo.update()

      Logger.warning("[MFA] #{account.email} 이(가) 백업 코드를 사용했습니다. 남은 코드 #{length(remaining)}개")

      :ok
    else
      {:error, :invalid_code}
    end
  end
end
