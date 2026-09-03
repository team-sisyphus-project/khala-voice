defmodule VR.Workers.TranscriptionWorker do
  @moduledoc """
  Transcribes one recording session.

  **Source: sisyphus** `lib/sisyphus/workers/meeting_transcription_worker.ex`
  — the billing call site was switched to `VR.Transcription.charge/2`.

  ## Flow

      1. Status → transcribing
      2. Convert to MP3 (skipped if already MP3)
      3. Call Google STT (5s polling, up to 30 minutes)
      4. Save transcript, status → completed
      5. Meter credits
      6. Refresh meeting aggregates

  ## Timeout

  Download (5 min) + conversion (10 min) + STT polling (30 min) + post-processing
  = up to 60 minutes. Much longer than Oban's default, so it is explicit.
  """

  use Oban.Worker, queue: :transcription, max_attempts: 3, priority: 2

  alias VR.Meetings
  alias VR.Transcription
  alias VR.Transcription.{Audio, GoogleSTT}

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(60)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id}, attempt: attempt}) do
    Logger.info("[Transcription] started: #{session_id} (attempt #{attempt})")

    case Meetings.get_session(session_id) do
      nil ->
        # The session is gone. Retrying will not help.
        {:cancel, :session_not_found}

      %{audio_url: nil} ->
        {:cancel, :no_audio}

      session ->
        run(session, attempt)
    end
  end

  defp run(session, attempt) do
    {:ok, session} = Meetings.set_session_status(session, "transcribing")
    meeting = Meetings.get_meeting(session.meeting_id)

    # Sent by the client (`apps/web/src/lib/prefs.ts`). It **must match** the
    # default over there, so sessions that arrived without a language are not
    # transcribed in a different one.
    language = get_in(session.metadata, ["language"]) || "en-US"

    with {:ok, audio_url, mime_type} <- prepare_audio(session),
         {:ok, segments} <-
           GoogleSTT.transcribe(audio_url, language: language, mime_type: mime_type) do
      finish(session, meeting, segments)
    else
      {:error, reason} ->
        fail(session, reason, attempt)
    end
  end

  # Normalized to MP3 for STT stability. Used as-is if already MP3.
  defp prepare_audio(session) do
    cond do
      GoogleSTT.dev_mode?() ->
        {:ok, session.audio_url, session.mime_type || "audio/mpeg"}

      Audio.mp3?(session.mime_type) ->
        {:ok, session.audio_url, "audio/mpeg"}

      not Audio.available?() ->
        {:error, :ffmpeg_missing}

      true ->
        transcode(session)
    end
  end

  defp transcode(session) do
    dir = Path.join(System.tmp_dir!(), "vr-stt-#{session.id}")
    File.mkdir_p!(dir)

    source = Path.join(dir, "source")
    target = Path.join(dir, "audio.mp3")

    try do
      with {:ok, body} <- download(session.audio_url),
           :ok <- File.write(source, body),
           {:ok, _} <- Audio.to_mp3(source, target),
           {:ok, uploaded} <- upload_mp3(session, target) do
        {:ok, uploaded.download_url, "audio/mpeg"}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp upload_mp3(session, path) do
    key =
      VR.Storage.recording_key(
        session.meeting_id,
        session.id,
        session.started_at_unix,
        "mp3"
      )

    VR.Storage.put_object(key, File.read!(path), "audio/mpeg")
  end

  # **The URL is checked and redirects are not followed.**
  #
  # This address used to come from the client (the server builds it now).
  # GETting it unchecked can send the server to private networks or cloud
  # metadata on the client's behalf (SSRF). Following redirects would neutralize
  # the allowed-host check outright, so it stays at 0.
  defp download(url) do
    if VR.Storage.own_object_url?(url) do
      case Req.get(url, receive_timeout: 300_000, max_redirects: 0) do
        {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:download_failed, status}}
        {:error, reason} -> {:error, {:download_error, reason}}
      end
    else
      Logger.error("[Storage] refusing to download an address that is not our own object")
      {:error, :untrusted_audio_url}
    end
  end

  defp finish(session, meeting, segments) do
    transcript = %{
      "segments" => Enum.map(segments, &normalize_segment/1),
      # The original is kept so the user can revert after editing
      "original_segments" => Enum.map(segments, &normalize_segment/1)
    }

    {:ok, session} =
      Meetings.update_transcript(session, %{
        transcript: transcript,
        speaker_map: initial_speaker_map(segments)
      })

    {:ok, _} = Meetings.set_session_status(session, "completed")

    # A metering failure does not roll back the transcription. The work is done.
    if meeting do
      case Transcription.charge(session, meeting.owner_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("[Transcription] metering failed: #{inspect(reason)}")
      end

      Meetings.recalculate_totals(meeting)
      maybe_summarize(meeting)

      # Notifications are auxiliary. Their failure does not roll back the transcription.
      VR.Push.notify(
        meeting.owner_id,
        meeting.title || "Meeting",
        "Transcription is complete.",
        url: "/go/meetings/#{meeting.id}",
        # Prevents notifications for the same meeting from piling up
        tag: "transcribe:#{meeting.id}"
      )
    end

    Logger.info("[Transcription] done: #{session.id}, #{length(segments)} segments")
    :ok
  end

  # Enqueues a summary once transcription is finished.
  #
  # **Not enqueued while any session is still transcribing.** Relying only on
  # the worker's 60-second unique is not enough — chunks finish minutes apart
  # and fall outside that window. A half summary built from only the chunks that
  # finished first would then be saved, and the later chunk's auto job would be
  # skipped by `has_summary?`. The result is "there is a summary, but its tail
  # is missing", with no way for the user to know.
  defp maybe_summarize(meeting) do
    cond do
      VR.Meetings.transcription_pending?(meeting.id) ->
        Logger.info("[Transcription] sessions remaining; deferring summary: #{meeting.id}")
        :ok

      true ->
        do_summarize(meeting)
    end
  end

  defp do_summarize(meeting) do
    if VR.Config.fetch("llm.auto_summarize") in [true, "true"] and VR.Summarize.ready?() do
      case VR.Summarize.enqueue(meeting, "auto") do
        {:ok, _job} -> :ok
        {:error, reason} -> Logger.warning("[Transcription] summary enqueue failed: #{inspect(reason)}")
      end
    end
  end

  defp normalize_segment(segment) do
    %{
      "speaker" => segment.speaker,
      "text" => segment.text,
      "start_ms" => segment.start_ms,
      "end_ms" => segment.end_ms,
      "confidence" => segment.confidence
    }
  end

  # Each speaker key starts with an empty name. The user attaches people later.
  defp initial_speaker_map(segments) do
    segments
    |> Enum.map(& &1.speaker)
    |> Enum.uniq()
    |> Enum.with_index(1)
    |> Map.new(fn {key, index} ->
      {key, %{"name" => "Speaker #{index}", "account_id" => nil}}
    end)
  end

  defp fail(session, reason, attempt) do
    Logger.error("[Transcription] failed: #{session.id} — #{inspect(reason)}")

    message = describe(reason)

    # Only the last attempt hardens the status to failed. Retries remain before that.
    if attempt >= 3 do
      Meetings.set_session_status(session, "failed", %{error_message: message})
    end

    {:error, reason}
  end

  defp describe(:ffmpeg_missing),
    do: "FFmpeg is not installed on the server, so the audio could not be converted"

  defp describe({:missing_config, key}), do: "Transcription setup is incomplete (#{key})"
  defp describe(:transcription_timeout), do: "Transcription did not finish in time"
  defp describe({:transcription_failed, _}), do: "Speech could not be recognized"
  defp describe({:download_failed, status}), do: "The audio could not be downloaded (#{status})"
  defp describe(_), do: "Transcription failed"
end
