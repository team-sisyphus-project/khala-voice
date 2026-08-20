defmodule VR.Meetings.RecordingSession do
  @moduledoc """
  녹음 1건. 독립적으로 업로드 → 전사 흐름을 탄다.

  **출처: sisyphus** `lib/sisyphus/meetings/recording_session.ex` — 거의 그대로.

  ## 상태

      recording ─► uploaded ─┬─► transcribing ─► completed
                             │                └─► failed
                             └─► splitting ──► (청크별 새 세션 생성, 원본 삭제)

  ## 파일명

  `started_at_unix` 를 그대로 쓴다 — `{started_at_unix}.webm` / `.json`.
  같은 회의 안에서 시간순 정렬이 파일명만으로 되고, 충돌하지 않는다.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @statuses ~w(recording uploaded splitting transcribing completed failed)

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "recording_sessions" do
    field :meeting_id, :string
    field :session_index, :integer, default: 1
    field :status, :string, default: "recording"
    field :started_at_unix, :integer
    field :duration_seconds, :integer

    field :audio_url, :string
    # 서버가 정한 업로드 대상 키. 재생·전사는 전부 이 키로만 접근한다.
    field :storage_key, :string
    field :transcript_url, :string
    field :transcript, :map
    field :speaker_map, :map, default: %{}

    field :credits_charged, :integer, default: 0
    field :file_size_bytes, :integer
    field :mime_type, :string
    field :metadata, :map, default: %{}
    field :error_message, :string

    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [:meeting_id, :session_index, :started_at_unix, :metadata])
    |> put_id()
    |> put_started_at()
    |> validate_required([:id, :meeting_id, :started_at_unix])
  end

  @doc """
  업로드 완료 등록. 클라이언트가 S3에 올린 뒤 호출한다.

  **`audio_url` 을 클라이언트에서 받지 않는다.** 서버가 `storage_key` 로 만든다 —
  클라이언트가 준 주소는 워커의 다운로드로 흘러들어가 SSRF 가 된다.
  """
  def upload_changeset(session, attrs) do
    session
    |> cast(attrs, [:duration_seconds, :file_size_bytes, :mime_type])
    |> put_change(:status, "uploaded")
    |> validate_number(:duration_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:file_size_bytes, greater_than: 0)
  end

  @doc "presign 단계에서 서버가 정한 저장 키를 박는다."
  def storage_key_changeset(session, key) when is_binary(key) do
    change(session, %{storage_key: key})
  end

  def status_changeset(session, status, attrs \\ %{}) when status in @statuses do
    session
    |> cast(attrs, [:error_message])
    |> put_change(:status, status)
  end

  def transcript_changeset(session, attrs) do
    session
    |> cast(attrs, [:transcript, :transcript_url, :speaker_map, :credits_charged])
    |> validate_transcript()
  end

  @doc "화자 매핑만 갱신 (칩 변경)."
  def speaker_map_changeset(session, speaker_map) do
    change(session, %{speaker_map: speaker_map})
  end

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:recording_session))
      "" -> put_change(changeset, :id, IdGenerator.generate(:recording_session))
      _ -> changeset
    end
  end

  defp put_started_at(changeset) do
    case get_field(changeset, :started_at_unix) do
      nil -> put_change(changeset, :started_at_unix, System.system_time(:second))
      _ -> changeset
    end
  end

  # 세그먼트 구조가 깨지면 전사 화면 전체가 망가진다. 저장 전에 막는다.
  defp validate_transcript(changeset) do
    case get_change(changeset, :transcript) do
      nil ->
        changeset

      %{"segments" => segments} when is_list(segments) ->
        if Enum.all?(segments, &valid_segment?/1) do
          changeset
        else
          add_error(changeset, :transcript, "세그먼트 형식이 올바르지 않습니다")
        end

      _ ->
        add_error(changeset, :transcript, "segments 배열이 필요합니다")
    end
  end

  defp valid_segment?(%{"speaker" => s, "text" => t, "start_ms" => sm, "end_ms" => em})
       when is_binary(s) and is_binary(t) and is_integer(sm) and is_integer(em),
       do: true

  defp valid_segment?(_), do: false
end
