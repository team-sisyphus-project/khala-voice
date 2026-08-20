defmodule VR.Workers.TranscriptionWorker do
  @moduledoc """
  녹음 세션 하나를 전사한다.

  **출처: sisyphus** `lib/sisyphus/workers/meeting_transcription_worker.ex`
  — 과금 호출부를 `VR.Transcription.charge/2` 로 바꿨다.

  ## 흐름

      1. 상태 → transcribing
      2. MP3 로 변환 (이미 MP3 면 건너뜀)
      3. Google STT 호출 (5초 폴링, 최대 30분)
      4. 전사 저장 · 상태 → completed
      5. 크레딧 계량
      6. 회의 집계 갱신

  ## 타임아웃

  다운로드(5분) + 변환(10분) + STT 폴링(30분) + 후처리 = 최대 60분.
  Oban 기본값보다 훨씬 길어 명시한다.
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
    Logger.info("[Transcription] 시작: #{session_id} (시도 #{attempt})")

    case Meetings.get_session(session_id) do
      nil ->
        # 세션이 사라졌다. 재시도해도 소용없다.
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

    # 클라이언트가 실어 보낸다 (`apps/web/src/lib/prefs.ts`). 그쪽 기본값과 **같아야**
    # 언어를 못 받은 세션이 다른 언어로 전사되지 않는다.
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

  # STT 안정성을 위해 MP3 로 맞춘다. 이미 MP3 면 그대로 쓴다.
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

  defp finish(session, meeting, segments) do
    transcript = %{
      "segments" => Enum.map(segments, &normalize_segment/1),
      # 사용자가 편집한 뒤 되돌릴 수 있게 원본을 남긴다
      "original_segments" => Enum.map(segments, &normalize_segment/1)
    }

    {:ok, session} =
      Meetings.update_transcript(session, %{
        transcript: transcript,
        speaker_map: initial_speaker_map(segments)
      })

    {:ok, _} = Meetings.set_session_status(session, "completed")

    # 계량 실패로 전사를 되돌리지 않는다. 일은 이미 끝났다.
    if meeting do
      case Transcription.charge(session, meeting.owner_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("[Transcription] 계량 실패: #{inspect(reason)}")
      end

      Meetings.recalculate_totals(meeting)
      maybe_summarize(meeting)

      # 알림은 부가 기능이다. 실패해도 전사를 되돌리지 않는다.
      VR.Push.notify(
        meeting.owner_id,
        meeting.title || "회의",
        "전사가 끝났습니다.",
        url: "/go/meetings/#{meeting.id}",
        # 같은 회의의 알림이 쌓이지 않게 한다
        tag: "transcribe:#{meeting.id}"
      )
    end

    Logger.info("[Transcription] 완료: #{session.id} 세그먼트 #{length(segments)}개")
    :ok
  end

  # 전사가 끝나면 요약을 큐잉한다.
  #
  # **아직 전사 중인 세션이 있으면 큐잉하지 않는다.** 워커의 60초 unique 에만
  # 기대면 안 된다 — 청크는 수 분 간격으로 끝나 그 창을 벗어난다. 그러면 먼저
  # 끝난 청크만으로 만든 반쪽 요약이 저장되고, 나중 청크의 auto 잡은
  # `has_summary?` 에 걸려 건너뛴다. 결과는 "요약은 있는데 뒷부분이 없는" 상태이고
  # 사용자는 그 사실을 알 방법이 없다.
  defp maybe_summarize(meeting) do
    cond do
      VR.Meetings.transcription_pending?(meeting.id) ->
        Logger.info("[Transcription] 남은 세션이 있어 요약을 미룬다: #{meeting.id}")
        :ok

      true ->
        do_summarize(meeting)
    end
  end

  defp do_summarize(meeting) do
    if VR.Config.fetch("llm.auto_summarize") in [true, "true"] and VR.Summarize.ready?() do
      case VR.Summarize.enqueue(meeting, "auto") do
        {:ok, _job} -> :ok
        {:error, reason} -> Logger.warning("[Transcription] 요약 큐잉 실패: #{inspect(reason)}")
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

  # 화자 키마다 빈 이름으로 시작한다. 사용자가 나중에 사람을 붙인다.
  defp initial_speaker_map(segments) do
    segments
    |> Enum.map(& &1.speaker)
    |> Enum.uniq()
    |> Enum.with_index(1)
    |> Map.new(fn {key, index} ->
      {key, %{"name" => "화자 #{index}", "account_id" => nil}}
    end)
  end

  defp fail(session, reason, attempt) do
    Logger.error("[Transcription] 실패: #{session.id} — #{inspect(reason)}")

    message = describe(reason)

    # 마지막 시도에서만 failed 로 굳힌다. 그전에는 재시도가 남아 있다.
    if attempt >= 3 do
      Meetings.set_session_status(session, "failed", %{error_message: message})
    end

    {:error, reason}
  end

  defp describe(:ffmpeg_missing),
    do: "서버에 FFmpeg 이 없어 오디오를 변환하지 못했습니다"

  defp describe({:missing_config, key}), do: "전사 설정이 완료되지 않았습니다 (#{key})"
  defp describe(:transcription_timeout), do: "전사가 시간 안에 끝나지 않았습니다"
  defp describe({:transcription_failed, _}), do: "음성을 인식하지 못했습니다"
  defp describe({:download_failed, status}), do: "오디오를 내려받지 못했습니다 (#{status})"
  defp describe(_), do: "전사에 실패했습니다"
end
