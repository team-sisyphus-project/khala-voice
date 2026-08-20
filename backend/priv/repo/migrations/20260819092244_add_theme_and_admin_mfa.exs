defmodule VR.Repo.Migrations.AddThemeAndAdminMfa do
  use Ecto.Migration

  @moduledoc """
  사용자별 테마 설정과 시스템 어드민 2단계 인증.

  ## 테마

  **사용자마다 고르는 값이다.** 시스템 어드민이 정하는 것이 아니다.
  로그인 전에도 화면이 필요하므로 localStorage 에 캐시하고, 여기는 정본이다.

  ## MFA

  **시스템 어드민에게만** 해당한다. 일반 사용자에게는 노출하지 않는다.
  시스템 어드민은 전체 시스템의 운영자이므로 계정이 뚫리면 피해 범위가 다르다.
  """

  def change do
    alter table(:accounts) do
      add :theme, :string, null: false, default: "light"

      # TOTP 비밀키. Cloak 으로 암호화해 저장한다 —
      # 평문으로 새면 2단계 인증의 의미가 사라진다.
      add :mfa_secret_encrypted, :binary
      add :mfa_enabled, :boolean, null: false, default: false
      add :mfa_enabled_at, :utc_datetime
      # 인증기를 잃었을 때 쓰는 일회용 코드. 해시로만 저장한다.
      add :mfa_backup_hashes, {:array, :string}, null: false, default: []
    end
  end
end
