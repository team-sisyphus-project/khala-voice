defmodule VR.Meetings.RecordingSession do
  @moduledoc """
  One recording. Rides the upload → transcription flow independently.

  **Source: sisyphus** `lib/sisyphus/meetings/recording_session.ex` — nearly verbatim.

  ## Status

      recording ─► uploaded ─┬─► transcribing ─► completed
                             │                └─► failed
                             └─► splitting ──► (new session per chunk, original deleted)

  ## Filenames

  `started_at_unix` is used directly — `{started_at_unix}.webm` / `.json`.
  Within a meeting, chronological sorting works on the filename alone, without collisions.
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
    # The upload target key the server chose. Playback and transcription access only through this key.
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
  Register upload completion. Called after the client has uploaded to S3.

  **`audio_url` is not accepted from the client.** The server builds it from
  `storage_key` — a client-supplied URL would flow into the worker's download
  and become SSRF.
  """
  def upload_changeset(session, attrs) do
    session
    |> cast(attrs, [:duration_seconds, :file_size_bytes, :mime_type])
    |> put_change(:status, "uploaded")
    |> validate_number(:duration_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:file_size_bytes, greater_than: 0)
  end

  @doc "Set the storage key the server chose during the presign step."
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

  @doc "Update only the speaker mapping (chip changes)."
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

  # A broken segment structure wrecks the entire transcript view. Block it before saving.
  defp validate_transcript(changeset) do
    case get_change(changeset, :transcript) do
      nil ->
        changeset

      %{"segments" => segments} when is_list(segments) ->
        if Enum.all?(segments, &valid_segment?/1) do
          changeset
        else
          add_error(changeset, :transcript, "contains segments with an invalid format")
        end

      _ ->
        add_error(changeset, :transcript, "must include a segments array")
    end
  end

  defp valid_segment?(%{"speaker" => s, "text" => t, "start_ms" => sm, "end_ms" => em})
       when is_binary(s) and is_binary(t) and is_integer(sm) and is_integer(em),
       do: true

  defp valid_segment?(_), do: false
end
