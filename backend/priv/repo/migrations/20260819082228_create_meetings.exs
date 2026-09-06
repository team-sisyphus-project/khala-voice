defmodule VR.Repo.Migrations.CreateMeetings do
  use Ecto.Migration

  @moduledoc """
  Meetings · recording sessions · taxonomy (topics/labels).

  A pg_trgm index backs transcript search. Trigram partial matching is good
  enough without a dedicated search engine, even for languages that would
  otherwise need morphological analysis.
  """

  def change do
    execute &ensure_pg_trgm!/0, "DROP EXTENSION IF EXISTS pg_trgm"

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

  # Up step for the pg_trgm extension. `CREATE EXTENSION IF NOT EXISTS` keeps
  # the happy path idempotent, but when the database account lacks the privilege
  # the raw Postgrex `insufficient_privilege` error does not say what to do — so
  # we pre-check and raise a message naming the extension and the exact SQL a
  # database administrator must run before migrating.
  # (Deliberately duplicated from CreateAccounts: migration files must stay
  # self-contained — no dependencies on application code that may change.)
  defp ensure_pg_trgm! do
    ext = "pg_trgm"

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
