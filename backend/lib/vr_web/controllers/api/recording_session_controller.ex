defmodule VRWeb.API.RecordingSessionController do
  @moduledoc """
  Recording session REST API.

  ## Flow

      POST /api/meetings/:id/sessions      create a session (start recording)
      POST /api/uploads/presign            issue an upload URL
      (the browser PUTs directly to S3)
      POST /api/sessions/:id/upload        register the upload
      POST /api/sessions/:id/transcribe    queue transcription  <- M3
  """

  use VRWeb, :controller

  alias VR.{Meetings, Storage}
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  def create(conn, %{"meeting_id" => meeting_id} = params) do
    account = conn.assigns.current_account

    with {:ok, meeting, level} <- Meetings.authorize(meeting_id, account, :lv1),
         :ok <- ensure_active(meeting),
         {:ok, session} <-
           Meetings.create_session(meeting, Map.take(params, ~w(started_at_unix metadata))) do
      conn
      |> put_status(:created)
      |> json(JSONView.session(session, level))
    end
  end

  @doc "Notifies the server after the S3 upload has finished."
  def upload(conn, %{"id" => id} = params) do
    account = conn.assigns.current_account

    with {:ok, session} <- load_session(id),
         {:ok, meeting, level} <- Meetings.authorize(session.meeting_id, account, :lv1),
         :ok <- ensure_mutable(meeting),
         :ok <- validate_mime(params["mime_type"]),
         # audio_url is not accepted. The server derives it from storage_key.
         {:ok, updated} <-
           Meetings.register_upload(
             session,
             Map.take(params, ~w(duration_seconds file_size_bytes mime_type))
           ) do
      Meetings.recalculate_totals(meeting)
      json(conn, JSONView.session(updated, level))
    end
  end

  @doc "Starts transcription. Recordings over 20 minutes go to the chunking worker."
  def transcribe(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, session} <- load_session(id),
         {:ok, meeting, level} <- Meetings.authorize(session.meeting_id, account, :lv1),
         :ok <- ensure_mutable(meeting),
         :ok <- ensure_transcribable(session),
         {:ok, _job} <- VR.Transcription.enqueue(session) do
      # Queue only and respond immediately. Completion is reported via polling/SSE.
      conn
      |> put_status(:accepted)
      |> json(JSONView.session(Meetings.get_session(session.id), level))
    end
  end

  defp ensure_transcribable(%{status: status}) when status in ~w(uploaded failed completed),
    do: :ok

  defp ensure_transcribable(_session), do: {:error, :not_transcribable}

  def delete(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, session} <- load_session(id),
         {:ok, meeting, _level} <- Meetings.authorize(session.meeting_id, account, :lv0),
         {:ok, _} <- Meetings.delete_session(session) do
      Meetings.recalculate_totals(meeting)
      send_resp(conn, :no_content, "")
    end
  end

  @doc "Updates the speaker mapping or the transcript body."
  def update_speakers(conn, %{"id" => id} = params) do
    account = conn.assigns.current_account

    with {:ok, session} <- load_session(id),
         {:ok, meeting, level} <- Meetings.authorize(session.meeting_id, account, :lv1),
         :ok <- ensure_mutable(meeting),
         {:ok, updated} <- apply_speaker_update(session, params) do
      json(conn, JSONView.session(updated, level))
    end
  end

  @doc """
  Serves the audio. **Redirects to a signed URL.**

  We do not stream the file through the app server — an hour-long recording is
  tens of megabytes. The signature expires quickly, so a leaked link dies soon.

  Viewers (lv2) never reach this point. `authorize(:lv1)` returns
  `{:error, :not_found}` and a 404 goes out — a 403 would reveal that the
  meeting exists.
  """
  def audio(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, session} <- load_session(id),
         {:ok, _meeting, _level} <- Meetings.authorize(session.meeting_id, account, :lv1),
         {:ok, url} <- presign_audio(session) do
      redirect(conn, external: url)
    end
  end

  # A session without a key (dev seeds, etc.) has nothing to serve
  defp presign_audio(%{storage_key: key} = session) when is_binary(key) and key != "" do
    VR.Storage.presign_download(key, expires_in: playback_ttl(session))
  end

  defp presign_audio(_session), do: {:error, :not_found}

  # The signature must not expire before playback finishes.
  #
  # The browser keeps issuing Range requests against the **signed address** it was
  # redirected to. A fixed 5 minutes would cut off an hour-long meeting at the
  # 5-minute mark. So the TTL scales with duration, with an upper bound in case
  # the link leaks. A configured value, when present, is followed as-is
  # (the operator's judgment takes precedence).
  @min_playback_ttl 900
  @max_playback_ttl 21_600

  defp playback_ttl(%{duration_seconds: seconds}) when is_integer(seconds) and seconds > 0 do
    (seconds * 3)
    |> max(@min_playback_ttl)
    |> min(@max_playback_ttl)
  end

  defp playback_ttl(_session), do: @min_playback_ttl

  # Archived meetings are read-only. Previously this guard only applied to create,
  # so transcripts could still be edited after archiving.
  defp ensure_mutable(%{status: "archived"}), do: {:error, :meeting_archived}
  defp ensure_mutable(_meeting), do: :ok

  # ── Internal ────────────────────────────────────────────

  defp apply_speaker_update(session, params) do
    attrs =
      %{}
      |> maybe_put(:speaker_map, params["speaker_map"])
      |> maybe_put(:transcript, params["transcript"])

    if attrs == %{} do
      {:error, :nothing_to_update}
    else
      Meetings.update_transcript(session, attrs)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp load_session(id) do
    case Meetings.get_session(id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  defp ensure_active(%{status: "active"}), do: :ok
  defp ensure_active(_meeting), do: {:error, :meeting_not_active}

  defp validate_mime(nil), do: :ok

  defp validate_mime(mime) do
    if Storage.allowed_mime?(mime), do: :ok, else: {:error, :unsupported_media_type}
  end
end
