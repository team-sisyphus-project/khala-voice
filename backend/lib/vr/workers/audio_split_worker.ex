defmodule VR.Workers.AudioSplitWorker do
  @moduledoc """
  20분을 넘는 녹음을 19분 단위로 자르고, 청크마다 새 세션을 만든다.

  **출처: sisyphus** `lib/sisyphus/workers/audio_split_worker.ex`
  — 업로드 경로만 이 앱의 `VR.Storage` 로 바꿨다.

  ## 흐름

      1. 원본 다운로드
      2. FFmpeg 로 19분 단위 분할
      3. 청크를 스토리지에 업로드
      4. 청크별 새 세션 생성 (metadata.part 에 구간 표시)
      5. 원본 세션 삭제
      6. 청크마다 전사 큐잉

  ## 화자 번호는 청크마다 독립적이다

  청크 1의 `speaker_1` 과 청크 2의 `speaker_1` 이 같은 사람이라는 보장이 없다.
  STT 가 파일 단위로 화자를 나누기 때문이다. 화면에서 이걸 알려줘야 한다.
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
    Logger.info("[AudioSplit] 시작: #{session_id}")

    case Meetings.get_session(session_id) do
      nil -> {:cancel, :session_not_found}
      %{audio_url: nil} -> {:cancel, :no_audio}
      session -> run(session)
    end
  end

  defp run(session) do
    cond do
      not Audio.available?() ->
        fail(session, "서버에 FFmpeg 이 없어 긴 녹음을 분할하지 못했습니다")

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
        # 원본은 지운다 — 청크들로 대체됐다
        {:ok, _} = Meetings.delete_session(session)

        Enum.each(created, &Transcription.enqueue/1)
        Meetings.recalculate_totals(meeting)

        Logger.info("[AudioSplit] 완료: #{session.id} → 청크 #{length(created)}개")
        :ok
      else
        {:error, reason} ->
          Logger.error("[AudioSplit] 실패: #{session.id} — #{inspect(reason)}")
          fail(session, "긴 녹음을 분할하지 못했습니다")
      end
    after
      File.rm_rf(dir)
    end
  end

  # duration_seconds 를 못 믿을 때가 있다 (webm 헤더가 Infinity 를 주는 등).
  # 파일에서 직접 잰다.
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

  # **URL 을 검사하고 리다이렉트를 따라가지 않는다.**
  #
  # 이 주소는 예전에 클라이언트가 보내주던 값이었다 (지금은 서버가 만든다).
  # 검사 없이 GET 하면 사설망·클라우드 메타데이터로 서버를 대신 보낼 수 있다 (SSRF).
  # 리다이렉트를 따라가면 허용 호스트 검사가 그대로 무력해지므로 0 으로 둔다.
  defp download(url) do
    if VR.Storage.own_object_url?(url) do
      case Req.get(url, receive_timeout: 300_000, max_redirects: 0) do
        {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:download_failed, status}}
        {:error, reason} -> {:error, {:download_error, reason}}
      end
    else
      Logger.error("[Storage] 우리 오브젝트가 아닌 주소는 내려받지 않습니다")
      {:error, :untrusted_audio_url}
    end
  end

  defp fail(session, message) do
    Meetings.set_session_status(session, "failed", %{error_message: message})
    {:cancel, :split_failed}
  end
end
