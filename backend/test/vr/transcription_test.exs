defmodule VR.TranscriptionTest do
  use VR.DataCase, async: false

  import VR.AccountsFixtures

  alias VR.Billing.Credits
  alias VR.Config
  alias VR.Meetings
  alias VR.Transcription
  alias VR.Transcription.{Audio, GoogleSTT}

  setup do
    # 개발 모드 — 실제 GCP 호출 없이 목 결과를 받는다
    {:ok, _} = Config.put("stt.dev_mode", "true")
    {:ok, _} = Config.put("stt.cost_per_minute_usd", "0.016")
    {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})

    on_exit(fn ->
      Config.delete("stt.dev_mode")
      Config.delete("stt.cost_per_minute_usd")
    end)

    account = account_fixture()
    {:ok, meeting} = Meetings.create_meeting(account, %{title: "테스트 회의"})

    %{account: account, meeting: meeting}
  end

  defp uploaded_session(meeting, duration \\ 300) do
    {:ok, session} = Meetings.create_session(meeting)

    {:ok, session} =
      Meetings.register_upload(with_storage_key(session), %{
        duration_seconds: duration,
        file_size_bytes: 1_000_000,
        mime_type: "audio/mpeg"
      })

    session
  end

  describe "개발 모드" do
    test "GCP 자격증명 없이도 전사한다" do
      assert GoogleSTT.dev_mode?()
      assert {:ok, segments} = GoogleSTT.transcribe("https://cdn.test/a.mp3")

      assert length(segments) == 5
      assert %{speaker: "speaker_1", text: text, start_ms: 0} = hd(segments)
      assert text =~ "안녕하세요"
    end

    test "화자가 여러 명 나온다" do
      {:ok, segments} = GoogleSTT.transcribe("https://cdn.test/a.mp3")
      speakers = segments |> Enum.map(& &1.speaker) |> Enum.uniq()

      assert length(speakers) == 3
    end

    test "ready? 는 개발 모드에서 참이다" do
      assert Transcription.ready?()
    end
  end

  describe "큐잉" do
    test "짧은 녹음은 전사 워커로 간다", %{meeting: meeting} do
      session = uploaded_session(meeting, 300)

      assert {:ok, job} = Transcription.enqueue(session)
      assert job.worker == "VR.Workers.TranscriptionWorker"
    end

    test "20분을 넘으면 분할 워커로 간다", %{meeting: meeting} do
      session = uploaded_session(meeting, 25 * 60)

      assert {:ok, job} = Transcription.enqueue(session)
      assert job.worker == "VR.Workers.AudioSplitWorker"

      # 상태도 splitting 으로 바뀐다
      assert Meetings.get_session(session.id).status == "splitting"
    end

    test "정확히 20분은 분할하지 않는다", %{meeting: meeting} do
      session = uploaded_session(meeting, 20 * 60)

      assert {:ok, job} = Transcription.enqueue(session)
      assert job.worker == "VR.Workers.TranscriptionWorker"
    end

    test "오디오가 없으면 거부한다", %{meeting: meeting} do
      {:ok, session} = Meetings.create_session(meeting)
      assert {:error, :no_audio} = Transcription.enqueue(session)
    end
  end

  describe "전사 워커" do
    test "전사하고 화자 맵을 만든다", %{meeting: meeting, account: account} do
      session = uploaded_session(meeting)

      assert :ok =
               perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})

      done = Meetings.get_session(session.id)
      assert done.status == "completed"
      assert length(done.transcript["segments"]) == 5
      # 원본을 남겨 편집 후 복원할 수 있다
      assert length(done.transcript["original_segments"]) == 5

      # 화자마다 기본 이름이 붙는다
      assert map_size(done.speaker_map) == 3
      assert %{"name" => "화자 1"} = done.speaker_map["speaker_1"]

      _ = account
    end

    test "크레딧을 계량한다", %{meeting: meeting, account: account} do
      {:ok, _} = Credits.grant(account.id, 1000)
      session = uploaded_session(meeting, 600)

      :ok = perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})

      # 10분 × $0.016 = $0.16 → $0.16/$0.0015 = 106.67 → 올림 107
      [entry | _] = Credits.list_ledger(account.id)
      assert entry.source == "usage"
      assert entry.charge_domain == "stt"
      assert entry.charged_credits == 107
      assert Credits.balance(account.id) == 893
    end

    test "단가가 없으면 계량을 건너뛰되 전사는 성공한다", %{meeting: meeting, account: account} do
      Config.delete("stt.cost_per_minute_usd")
      session = uploaded_session(meeting)

      assert :ok = perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})
      assert Meetings.get_session(session.id).status == "completed"
      assert Credits.list_ledger(account.id) == []
    end

    test "재시도돼도 두 번 계량되지 않는다", %{meeting: meeting, account: account} do
      {:ok, _} = Credits.grant(account.id, 1000)
      session = uploaded_session(meeting, 600)

      :ok = perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})
      balance_after_first = Credits.balance(account.id)

      # 같은 세션을 다시 돌린다 (워커 재시도 상황)
      :ok = perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})

      assert Credits.balance(account.id) == balance_after_first
    end

    test "회의 집계가 갱신된다", %{meeting: meeting} do
      session = uploaded_session(meeting, 600)

      :ok = perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})

      assert Meetings.get_meeting(meeting.id).total_duration_seconds == 600
    end

    test "없는 세션은 취소한다" do
      assert {:cancel, :session_not_found} =
               perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => "mrss_nope"})
    end

    test "오디오가 없으면 취소한다", %{meeting: meeting} do
      {:ok, session} = Meetings.create_session(meeting)

      assert {:cancel, :no_audio} =
               perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})
    end
  end

  describe "오디오 유틸" do
    test "분할 임계값" do
      refute Audio.needs_splitting?(20 * 60)
      assert Audio.needs_splitting?(20 * 60 + 1)
      refute Audio.needs_splitting?(nil)
    end

    test "MP3 판정" do
      assert Audio.mp3?("audio/mpeg")
      assert Audio.mp3?("audio/mp3")
      refute Audio.mp3?("audio/webm")
      refute Audio.mp3?(nil)
    end

    test "구간 라벨" do
      assert Audio.range_label(0, 19 * 60) == "0:00~19:00"
      assert Audio.range_label(19 * 60, 19 * 60) == "19:00~38:00"
      assert Audio.range_label(0, 65) == "0:00~1:05"
    end
  end
end
