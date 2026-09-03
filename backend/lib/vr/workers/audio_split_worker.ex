defmodule VR.Workers.AudioSplitWorker do
  @moduledoc """
  Cuts recordings over 20 minutes into 19-minute chunks and creates a new
  session per chunk.

  **Source: sisyphus** `lib/sisyphus/workers/audio_split_worker.ex`
  — only the upload path was switched to this app's `VR.Storage`.

  ## Flow

      1. Download the original
      2. Split into 19-minute chunks with FFmpeg
      3. Upload the chunks to storage
      4. Create a new session per chunk (range marked in metadata.part)
      5. Delete the original session
      6. Enqueue transcription per chunk

  ## Speaker numbers are independent per chunk

  There is no guarantee that `speaker_1` in chunk 1 and `speaker_1` in chunk 2
  are the same person. STT diarizes speakers per file. The UI has to make this
  clear.
  """

  use Oban.Worker, queue: :transcription, max_attempts: 2, priority: 1

  alias VR.Meetings
  alias VR.Storage
  alias VR.Transcription
  alias VR.Transcription.Audio

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id}}) do
    Logger.info("[AudioSplit] started: #{session_id}")

    case Meetings.get_session(session_id) do
      nil -> {:cancel, :session_not_found}
      %{audio_url: nil} -> {:cancel, :no_audio}
      session -> run(session)
    end
  end

  defp run(session) do
    cond do
      not Audio.available?() ->
        fail(session, "FFmpeg is not installed on the server, so the long recording could not be split")

      true ->
        split(session)
    end
  end

  defp split(session) do
    meeting = Meetings.get_meeting(session.meeting_id)
    dir = Path.join(System.tmp_dir!(), "vr-split-#{session.id}")
    File.mkdir_p!(dir)

    source = Path.join(dir, "source#{extension(session)}")

    try do
      with {:ok, body} <- download(session.audio_url),
           :ok <- File.write(source, body),
           {:ok, total} <- resolve_duration(source, session),
           {:ok, chunks} <- Audio.split(source, dir, total),
           {:ok, created} <- materialize(meeting, session, chunks) do
        # The original is deleted — it has been replaced by the chunks
        {:ok, _} = Meetings.delete_session(session)

        Enum.each(created, &Transcription.enqueue/1)
        Meetings.recalculate_totals(meeting)

        Logger.info("[AudioSplit] done: #{session.id} → #{length(created)} chunks")
        :ok
      else
        {:error, reason} ->
          Logger.error("[AudioSplit] failed: #{session.id} — #{inspect(reason)}")
          fail(session, "The long recording could not be split")
      end
    after
      File.rm_rf(dir)
    end
  end

  # duration_seconds cannot always be trusted (e.g. webm headers reporting
  # Infinity). Measure directly from the file.
  defp resolve_duration(path, session) do
    case Audio.duration(path) do
      {:ok, seconds} when seconds > 0 ->
        {:ok, seconds}

      _ ->
        if session.duration_seconds,
          do: {:ok, session.duration_seconds},
          else: {:error, :unknown_duration}
    end
  end

  defp materialize(meeting, session, chunks) do
    results =
      Enum.map(chunks, fn chunk ->
        with {:ok, created} <- create_chunk_session(meeting, session, chunk),
             {:ok, uploaded} <- upload_chunk(meeting, created, chunk),
             {:ok, registered} <- register(created, uploaded, chunk, session) do
          {:ok, registered}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, s} -> s end)}
      error -> error
    end
  end

  defp create_chunk_session(meeting, original, chunk) do
    Meetings.create_session(meeting, %{
      started_at_unix: original.started_at_unix + chunk.start_seconds,
      metadata:
        Map.merge(original.metadata || %{}, %{
          "part" => %{
            "index" => chunk.index,
            "start_seconds" => chunk.start_seconds,
            "label" => Audio.range_label(chunk.start_seconds, chunk.duration_seconds),
            "split_from" => original.id
          }
        })
    })
  end

  defp upload_chunk(meeting, session, chunk) do
    key =
      Storage.recording_key(
        meeting.id,
        session.id,
        session.started_at_unix,
        String.trim_leading(Path.extname(chunk.path), ".")
      )

    Storage.put_object(key, File.read!(chunk.path), content_type(chunk.path))
  end

  defp register(session, uploaded, chunk, original) do
    Meetings.register_upload(session, %{
      audio_url: uploaded.download_url,
      duration_seconds: chunk.duration_seconds,
      file_size_bytes: File.stat!(chunk.path).size,
      mime_type: original.mime_type || "audio/webm"
    })
  end

  defp extension(%{mime_type: mime}) when is_binary(mime),
    do: "." <> Storage.extension_for(mime)

  defp extension(_), do: ".webm"

  defp content_type(path) do
    case Path.extname(path) do
      ".webm" -> "audio/webm"
      ".m4a" -> "audio/mp4"
      ".mp3" -> "audio/mpeg"
      ".ogg" -> "audio/ogg"
      ".wav" -> "audio/wav"
      _ -> "application/octet-stream"
    end
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

  defp fail(session, message) do
    Meetings.set_session_status(session, "failed", %{error_message: message})
    {:cancel, :split_failed}
  end
end
