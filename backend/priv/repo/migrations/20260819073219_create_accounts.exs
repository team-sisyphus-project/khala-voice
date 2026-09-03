defmodule VR.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  @moduledoc """
  Accounts · sessions · email tokens · login attempts.

  IDs are prefixed strings (`acct_…`, `sess_…`, `atkn_…`).
  Tokens are stored as SHA-256 hashes only, never the originals.
  """

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:accounts, primary_key: false) do
      add :id, :string, primary_key: true
      # citext — case-insensitive. Foo@x.com and foo@x.com become the same account
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
    # A social ID must be unique within a given provider
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

    # Indexes for the queries that count recent failures
    create index(:login_attempts, [:email, :attempted_at])
    create index(:login_attempts, [:ip_address, :attempted_at])
  end
end
