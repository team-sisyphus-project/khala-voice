defmodule VR.Meetings.Meeting do
  @moduledoc """
  A meeting. A container holding multiple `RecordingSession`s.

  **Source: sisyphus** `lib/sisyphus/meetings/meeting.ex`
  — removed `project_id`, `meeting_type`, and legacy fields, and renamed `member_id` to `account_id`.

  ## Status

      active ──► completed ──► archived
        ▲            │
        └────────────┘   (the Reviewer can revert it)

  - `active` — recording is possible
  - `completed` — recording finished. Transcription and summarization may continue
  - `archived` — stored away. Hidden from lists by default; found via filters
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator
  alias VR.Meetings.RecordingSession

  @statuses ~w(active completed archived)

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "meetings" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "active"
    field :started_at, :utc_datetime

    # People
    field :owner_id, :string
    field :reviewer_id, :string
    field :contributor_ids, {:array, :string}, default: []
    field :permissions, :map, default: %{}
    field :guest_link_enabled, :boolean, default: false

    # Taxonomy
    field :topic_id, :string
    field :label_ids, {:array, :string}, default: []

    # Aggregate cache — summed from sessions
    field :total_duration_seconds, :integer, default: 0
    field :total_credits_charged, :integer, default: 0

    # Summary
    field :summary, :string
    field :decisions, {:array, :string}, default: []
    field :summary_data, :map
    field :last_summary_error, :map

    field :archived_at, :utc_datetime
    field :deleted_at, :utc_datetime

    has_many :recording_sessions, RecordingSession, foreign_key: :meeting_id

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc "Meeting creation. The creator becomes the Reviewer."
  def create_changeset(meeting, attrs) do
    meeting
    |> cast(attrs, [
      :title,
      :description,
      :owner_id,
      :reviewer_id,
      :started_at,
      :topic_id,
      :label_ids
    ])
    |> put_id()
    |> put_defaults()
    |> validate_required([:id, :owner_id, :reviewer_id])
    |> validate_length(:title, max: 200)
  end

  @doc "What Contributor and above can change."
  def update_changeset(meeting, attrs) do
    meeting
    |> cast(attrs, [:title, :description, :started_at, :topic_id, :label_ids])
    |> validate_length(:title, max: 200)
  end

  @doc "What only the Reviewer can change — visibility scope and participants."
  def permissions_changeset(meeting, attrs) do
    meeting
    |> cast(attrs, [:reviewer_id, :contributor_ids, :permissions, :guest_link_enabled])
    |> validate_required([:reviewer_id])
    |> validate_permissions()
  end

  def status_changeset(meeting, status) when status in @statuses do
    changes = %{status: status}

    changes =
      if status == "archived",
        do: Map.put(changes, :archived_at, DateTime.utc_now(:second)),
        else: Map.put(changes, :archived_at, nil)

    meeting |> change(changes) |> validate_inclusion(:status, @statuses)
  end

  def totals_changeset(meeting, duration, credits) do
    change(meeting, %{total_duration_seconds: duration, total_credits_charged: credits})
  end

  def summary_changeset(meeting, attrs) do
    cast(meeting, attrs, [:summary, :decisions, :summary_data, :last_summary_error])
  end

  # ── Internal ─────────────────────────────────────────────

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:meeting))
      "" -> put_change(changeset, :id, IdGenerator.generate(:meeting))
      _ -> changeset
    end
  end

  defp put_defaults(changeset) do
    changeset
    |> put_new(:title, fn -> default_title() end)
    |> put_new(:started_at, fn -> DateTime.utc_now(:second) end)
    |> put_new(:permissions, fn ->
      %{"view" => %{"mode" => "assignees_only", "accountIds" => []}}
    end)
  end

  # The schema default is %{}, so a nil check is not enough — an empty map also counts as empty
  defp put_new(changeset, field, fun) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, fun.())
      "" -> put_change(changeset, field, fun.())
      empty when empty == %{} -> put_change(changeset, field, fun.())
      _ -> changeset
    end
  end

  defp default_title do
    now = DateTime.utc_now()
    "Meeting on #{now.year}-#{now.month}-#{now.day}"
  end

  defp validate_permissions(changeset) do
    case get_field(changeset, :permissions) do
      %{"view" => %{"mode" => mode}} ->
        if mode in VR.Access.AccessLevel.view_scopes() do
          changeset
        else
          add_error(changeset, :permissions, "has an unknown visibility scope")
        end

      _ ->
        changeset
    end
  end
end
