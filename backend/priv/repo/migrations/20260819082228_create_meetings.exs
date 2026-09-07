defmodule VR.Repo.Migrations.CreateMeetings do
  use Ecto.Migration

  @moduledoc """
  Meetings · recording sessions · taxonomy (topics/labels).

  A pg_trgm index backs transcript search. Trigram partial matching is good
  enough without a dedicated search engine, even for languages that would
  otherwise need morphological analysis.
  """

  def change do
    execute &ensure_pg_trgm!/0, &drop_pg_trgm_if_owned!/0

    # ── Taxonomy ────────────────────────────────────────────
    create table(:topics, primary_key: false) do
      add :id, :string, primary_key: true
      add :owner_id, references(:accounts, type: :string, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color, :string
      add :sort_order, :integer, null: false, default: 0
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:topics, [:owner_id])

    create table(:labels, primary_key: false) do
      add :id, :string, primary_key: true
      add :owner_id, references(:accounts, type: :string, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color, :string
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:labels, [:owner_id])

    # ── Meetings ────────────────────────────────────────────
    create table(:meetings, primary_key: false) do
      add :id, :string, primary_key: true
      add :title, :string
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :started_at, :utc_datetime

      add :owner_id, references(:accounts, type: :string, on_delete: :delete_all), null: false
      add :reviewer_id, references(:accounts, type: :string, on_delete: :nilify_all)
      add :contributor_ids, {:array, :string}, null: false, default: []
      add :permissions, :map, null: false, default: %{}
      add :guest_link_enabled, :boolean, null: false, default: false

      add :topic_id, references(:topics, type: :string, on_delete: :nilify_all)
      add :label_ids, {:array, :string}, null: false, default: []

      add :total_duration_seconds, :integer, null: false, default: 0
      add :total_credits_charged, :integer, null: false, default: 0

      add :summary, :text
      add :decisions, {:array, :string}, null: false, default: []
      add :summary_data, :map
      add :last_summary_error, :map

      add :archived_at, :utc_datetime
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:meetings, [:owner_id])
    create index(:meetings, [:reviewer_id])
    create index(:meetings, [:status])
    create index(:meetings, [:topic_id])
    create index(:meetings, [:started_at])
    # For queries that find meetings someone joins as a contributor
    create index(:meetings, [:contributor_ids], using: :gin)
    create index(:meetings, [:label_ids], using: :gin)

    # Partial-match search on title/summary
    execute """
            CREATE INDEX meetings_title_trgm_idx ON meetings
            USING gin (coalesce(title, '') gin_trgm_ops)
            """,
            "DROP INDEX IF EXISTS meetings_title_trgm_idx"

    # ── Recording sessions ──────────────────────────────────
    create table(:recording_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :meeting_id, references(:meetings, type: :string, on_delete: :delete_all), null: false
      add :session_index, :integer, null: false, default: 1
      add :status, :string, null: false, default: "recording"
      add :started_at_unix, :bigint, null: false
      add :duration_seconds, :integer

      add :audio_url, :text
      add :transcript_url, :text
      add :transcript, :map
      add :speaker_map, :map, null: false, default: %{}

      add :credits_charged, :integer, null: false, default: 0
      add :file_size_bytes, :bigint
      add :mime_type, :string
      add :metadata, :map, null: false, default: %{}
      add :error_message, :text

      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:recording_sessions, [:meeting_id])
    create index(:recording_sessions, [:status])
    create unique_index(:recording_sessions, [:meeting_id, :session_index])
  end

  # ── PostgreSQL extension guard (pg_trgm) ──────────────────
  #
  # The schema depends on this extension — the `meetings_title_trgm_idx` GIN
  # index above is built with `gin_trgm_ops` — so the dependency cannot
  # simply be dropped; the only question is *who* creates it. Both supported
  # answers are handled here: an administrator pre-provisions it, or a role
  # that holds the privilege creates it on the spot. See
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

  @pg_trgm_extension "pg_trgm"

  defp ensure_pg_trgm!, do: ensure_extension!(repo(), @pg_trgm_extension)

  defp drop_pg_trgm_if_owned!, do: drop_extension_if_owned!(repo(), @pg_trgm_extension)

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
  # what the unqualified `gin_trgm_ops` operator class in the DDL above needs.
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
