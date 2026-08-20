defmodule VR.Meetings.Meeting do
  @moduledoc """
  회의. 여러 `RecordingSession`을 담는 컨테이너다.

  **출처: sisyphus** `lib/sisyphus/meetings/meeting.ex`
  — `project_id` · `meeting_type` · 레거시 필드를 제거하고 `member_id` 를 `account_id` 로 바꿨다.

  ## 상태

      active ──► completed ──► archived
        ▲            │
        └────────────┘   (Reviewer가 되돌릴 수 있다)

  - `active` — 녹음할 수 있다
  - `completed` — 녹음 종료. 전사·요약은 계속될 수 있다
  - `archived` — 보관됨. 목록에서 기본으로 숨기고 필터로 찾는다
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

    # 사람
    field :owner_id, :string
    field :reviewer_id, :string
    field :contributor_ids, {:array, :string}, default: []
    field :permissions, :map, default: %{}
    field :guest_link_enabled, :boolean, default: false

    # 분류
    field :topic_id, :string
    field :label_ids, {:array, :string}, default: []

    # 집계 캐시 — 세션에서 합산한다
    field :total_duration_seconds, :integer, default: 0
    field :total_credits_charged, :integer, default: 0

    # 요약
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

  @doc "회의 생성. 만든 사람이 Reviewer가 된다."
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

  @doc "Contributor 이상이 바꿀 수 있는 것."
  def update_changeset(meeting, attrs) do
    meeting
    |> cast(attrs, [:title, :description, :started_at, :topic_id, :label_ids])
    |> validate_length(:title, max: 200)
  end

  @doc "Reviewer만 바꿀 수 있는 것 — 공개 범위와 참여자."
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

  # ── 내부 ─────────────────────────────────────────────────

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

  # 스키마 기본값이 %{} 라서 nil 검사만으로는 부족하다 — 빈 맵도 비어 있는 것으로 본다
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
    "#{now.year}년 #{now.month}월 #{now.day}일 회의"
  end

  defp validate_permissions(changeset) do
    case get_field(changeset, :permissions) do
      %{"view" => %{"mode" => mode}} ->
        if mode in VR.Access.AccessLevel.view_scopes() do
          changeset
        else
          add_error(changeset, :permissions, "알 수 없는 공개 범위입니다")
        end

      _ ->
        changeset
    end
  end
end
