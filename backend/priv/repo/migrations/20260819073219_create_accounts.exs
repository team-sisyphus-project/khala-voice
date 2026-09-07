defmodule VR.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  @moduledoc """
  Accounts · sessions · email tokens · login attempts.

  IDs are prefixed strings (`acct_…`, `sess_…`, `atkn_…`).
  Tokens are stored as SHA-256 hashes only, never the originals.
  """

  def change do
    execute &ensure_citext!/0, &drop_citext_if_owned!/0

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

  # ── PostgreSQL extension guard (citext) ───────────────────
  #
  # The schema depends on this extension — `accounts.email` and
  # `login_attempts.email` below are `citext` columns — so the dependency
  # cannot simply be dropped; the only question is *who* creates it. Both
  # supported answers are handled here: an administrator pre-provisions it,
  # or a role that holds the privilege creates it on the spot. See
  # `docs/16-postgres-extension-privileges.md`.
  #
  # `CREATE EXTENSION IF NOT EXISTS` keeps the happy path idempotent, but on a
  # role without the privilege the raw Postgrex `insufficient_privilege` error
  # does not say what to do — so we pre-check and raise a message naming the
  # extension and the exact SQL a database administrator must run.
  #
  # Ownership is deliberately never required. A pre-provisioned extension is
  # owned by the administrator who created it, not by the migrating role: the
  # up direction only needs the extension to be *reachable*, and the down
  # direction drops only what this role actually owns.
  #
  # (Deliberately duplicated across migration files: migrations must stay
  # self-contained — no dependencies on application code that may change after
  # they were written.)

  @citext_extension "citext"

  defp ensure_citext!, do: ensure_extension!(repo(), @citext_extension)

  defp drop_citext_if_owned!, do: drop_extension_if_owned!(repo(), @citext_extension)

  @doc false
  def ensure_extension!(repo, ext) do
    cond do
      # Already reachable — typically pre-provisioned by an administrator.
      # Ownership is irrelevant here: resolving the extension's objects needs
      # no privilege beyond USAGE on the schema holding them.
      extension_reachable?(repo, ext) ->
        :ok

      extension_installed?(repo, ext) ->
        raise unreachable_message(repo, ext)

      not extension_available?(repo, ext) ->
        raise unavailable_message(ext)

      true ->
        create_extension!(repo, ext)
    end
  end

  # Rolling back must not remove an extension this migration did not create.
  # A pre-provisioned extension belongs to the administrator who created it and
  # may back other schemas in the same database — and `DROP EXTENSION` would be
  # refused for lack of ownership anyway, turning a rollback into a hard error.
  @doc false
  def drop_extension_if_owned!(repo, ext) do
    if extension_owned?(repo, ext) do
      repo.query!(~s(DROP EXTENSION IF EXISTS "#{ext}"))
      :ok
    else
      :skipped
    end
  end

  # True when the current role is the extension's owner, or a member of the
  # owning role (which is what `DROP EXTENSION` itself requires).
  @doc false
  def extension_owned?(repo, ext) do
    rows(
      repo,
      "SELECT 1 FROM pg_extension WHERE extname = $1 AND pg_has_role(extowner, 'USAGE')",
      [ext]
    ) != []
  end

  # Installed *and* in a schema on this role's effective search_path, which is
  # what the unqualified `:citext` column type in the DDL above needs.
  # An extension parked in a schema off the search_path is installed but
  # unusable, and PostgreSQL would report only "type ... does not exist".
  defp extension_reachable?(repo, ext) do
    rows(
      repo,
      """
      SELECT 1
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
       WHERE e.extname = $1
         AND n.nspname = ANY (current_schemas(true))
      """,
      [ext]
    ) != []
  end

  defp extension_installed?(repo, ext) do
    rows(repo, "SELECT 1 FROM pg_extension WHERE extname = $1", [ext]) != []
  end

  defp extension_available?(repo, ext) do
    rows(repo, "SELECT 1 FROM pg_available_extensions WHERE name = $1", [ext]) != []
  end

  defp create_extension!(repo, ext) do
    case repo.query(~s(CREATE EXTENSION IF NOT EXISTS "#{ext}")) do
      {:ok, _} ->
        :ok

      {:error, %{postgres: %{code: :insufficient_privilege}}} ->
        raise """
        the database account cannot create the PostgreSQL extension "#{ext}" \
        (insufficient privilege).

        A database administrator must create it before running migrations, by
        executing the following SQL on this database (as a superuser or a role
        with CREATE EXTENSION privilege):

            CREATE EXTENSION IF NOT EXISTS "#{ext}";

        Then re-run the migration.
        """

      {:error, error} ->
        raise "creating the PostgreSQL extension \"#{ext}\" failed: " <>
                Exception.message(error)
    end
  end

  defp unavailable_message(ext) do
    """
    the PostgreSQL extension "#{ext}" is not available on this server.

    A database administrator must install the PostgreSQL contrib package that
    provides "#{ext}" (e.g. postgresql-contrib), then create the extension
    before running migrations:

        CREATE EXTENSION IF NOT EXISTS "#{ext}";

    Then re-run the migration.
    """
  end

  defp unreachable_message(repo, ext) do
    schema = scalar(repo, extension_schema_sql(), [ext]) || "?"
    role = scalar(repo, "SELECT current_user", []) || "?"
    search_path = scalar(repo, search_path_sql(), []) || "?"

    """
    the PostgreSQL extension "#{ext}" is installed, but not where this migration
    can reach it — its types and operator classes cannot be resolved, so the
    migration would fail with a bare "does not exist" error.

        extension     "#{ext}"
        in schema     "#{schema}"
        role          "#{role}"
        search_path   #{search_path}

    A database administrator must make it reachable, either by moving the
    extension into a schema the role already searches:

        ALTER EXTENSION "#{ext}" SET SCHEMA public;

    or by adding its schema to the role's search_path:

        ALTER ROLE "#{role}" SET search_path = "$user", public, "#{schema}";

    Then re-run the migration.
    """
  end

  defp search_path_sql do
    "SELECT coalesce(nullif(array_to_string(current_schemas(false), ', '), ''), '(empty)')"
  end

  defp extension_schema_sql do
    """
    SELECT n.nspname
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = $1
    """
  end

  defp rows(repo, sql, params) do
    %{rows: rows} = repo.query!(sql, params)
    rows
  end

  defp scalar(repo, sql, params) do
    case rows(repo, sql, params) do
      [[value] | _] -> value
      _ -> nil
    end
  end
end
