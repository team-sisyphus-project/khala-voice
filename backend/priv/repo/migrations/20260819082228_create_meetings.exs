defmodule VR.Repo.Migrations.CreateMeetings do
  use Ecto.Migration

  @moduledoc """
  Meetings · recording sessions · taxonomy (topics/labels).

  A pg_trgm index backs transcript search. Trigram partial matching is good
  enough without a dedicated search engine, even for languages that would
  otherwise need morphological analysis.
  """

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm"

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
end
