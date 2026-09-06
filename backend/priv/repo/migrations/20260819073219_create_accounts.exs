defmodule VR.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  @moduledoc """
  Accounts · sessions · email tokens · login attempts.

  IDs are prefixed strings (`acct_…`, `sess_…`, `atkn_…`).
  Tokens are stored as SHA-256 hashes only, never the originals.
  """

  def change do
    execute &ensure_citext!/0, "DROP EXTENSION IF EXISTS citext"

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

  # Up step for the citext extension. `CREATE EXTENSION IF NOT EXISTS` keeps the
  # happy path idempotent, but when the database account lacks the privilege the
  # raw Postgrex `insufficient_privilege` error does not say what to do — so we
  # pre-check and raise a message naming the extension and the exact SQL a
  # database administrator must run before migrating.
  defp ensure_citext! do
    ext = "citext"

    cond do
      extension_installed?(ext) ->
        :ok

      not extension_available?(ext) ->
        raise """
        the PostgreSQL extension "#{ext}" is not available on this server.

        A database administrator must install the PostgreSQL contrib package
        that provides "#{ext}" (e.g. postgresql-contrib), then create the
        extension before running migrations:

            CREATE EXTENSION IF NOT EXISTS #{ext};
        """

      true ->
        create_extension!(ext)
    end
  end

  defp extension_installed?(ext) do
    %{rows: rows} = repo().query!("SELECT 1 FROM pg_extension WHERE extname = $1", [ext])
    rows != []
  end

  defp extension_available?(ext) do
    %{rows: rows} =
      repo().query!("SELECT 1 FROM pg_available_extensions WHERE name = $1", [ext])

    rows != []
  end

  defp create_extension!(ext) do
    case repo().query("CREATE EXTENSION IF NOT EXISTS #{ext}") do
      {:ok, _} ->
        :ok

      {:error, %{postgres: %{code: :insufficient_privilege}}} ->
        raise """
        the database account cannot create the PostgreSQL extension "#{ext}" \
        (insufficient privilege).

        A database administrator must create it before running migrations, by
        executing the following SQL on this database (as a superuser or a role
        with CREATE EXTENSION privilege):

            CREATE EXTENSION IF NOT EXISTS #{ext};

        Then re-run `mix ecto.migrate`.
        """

      {:error, error} ->
        raise "creating the PostgreSQL extension \"#{ext}\" failed: " <>
                Exception.message(error)
    end
  end
end
