defmodule VR.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  @moduledoc """
  계정 · 세션 · 이메일 토큰 · 로그인 시도.

  ID는 접두사가 붙은 문자열이다 (`acct_…`, `sess_…`, `atkn_…`).
  토큰은 원본이 아니라 SHA-256 해시만 저장한다.
  """

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:accounts, primary_key: false) do
      add :id, :string, primary_key: true
      # citext — 대소문자 무시. Foo@x.com 과 foo@x.com 이 같은 계정이 된다
      add :email, :citext, null: false
      add :hashed_password, :string
      add :name, :string
      add :confirmed_at, :utc_datetime

      add :locale, :string, null: false, default: "ko"
      add :country, :string
      add :time_zone, :string

      add :is_social, :boolean, null: false, default: false
      add :social_provider, :string
      add :social_id, :string

      add :is_admin, :boolean, null: false, default: false

      add :deleted_at, :utc_datetime
      add :scheduled_deletion_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:accounts, [:email])
    # 같은 제공자 안에서 소셜 ID는 유일해야 한다
    create unique_index(:accounts, [:social_provider, :social_id],
             where: "social_provider IS NOT NULL"
           )

    create index(:accounts, [:scheduled_deletion_at], where: "scheduled_deletion_at IS NOT NULL")

    create table(:account_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :user_agent, :string
      add :ip_address, :string
      add :last_activity_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:account_sessions, [:token_hash])
    create index(:account_sessions, [:account_id])

    create table(:account_tokens, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:account_tokens, [:token_hash])
    create index(:account_tokens, [:account_id, :context])

    create table(:login_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext
      add :ip_address, :string
      add :success, :boolean, null: false, default: false
      add :attempted_at, :utc_datetime, null: false
    end

    # 최근 실패 횟수를 세는 질의를 위한 인덱스
    create index(:login_attempts, [:email, :attempted_at])
    create index(:login_attempts, [:ip_address, :attempted_at])
  end
end
