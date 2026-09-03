defmodule VR.TranscriptionTest do
  use VR.DataCase, async: false

  import VR.AccountsFixtures

  alias VR.Billing.Credits
  alias VR.Config
  alias VR.Meetings
  alias VR.Transcription
  alias VR.Transcription.{Audio, GoogleSTT}

  setup do
    # Dev mode — returns mock results without real GCP calls
    {:ok, _} = Config.put("stt.dev_mode", "true")
    {:ok, _} = Config.put("stt.cost_per_minute_usd", "0.016")
    {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})

    on_exit(fn ->
      Config.delete("stt.dev_mode")
      Config.delete("stt.cost_per_minute_usd")
    end)

    account = account_fixture()
    {:ok, meeting} = Meetings.create_meeting(account, %{title: "Test Meeting"})

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

  describe "dev mode" do
    test "transcribes without GCP credentials" do
      assert GoogleSTT.dev_mode?()
      assert {:ok, segments} = GoogleSTT.transcribe("https://cdn.test/a.mp3")

      assert length(segments) == 5
      assert %{speaker: "speaker_1", text: text, start_ms: 0} = hd(segments)
      assert text =~ "Hello"
    end

    test "produces multiple speakers" do
      {:ok, segments} = GoogleSTT.transcribe("https://cdn.test/a.mp3")
      speakers = segments |> Enum.map(& &1.speaker) |> Enum.uniq()

      assert length(speakers) == 3
    end

    test "ready? is true in dev mode" do
      assert Transcription.ready?()
    end
  end

  describe "enqueueing" do
    test "short recordings go to the transcription worker", %{meeting: meeting} do
      session = uploaded_session(meeting, 300)

      assert {:ok, job} = Transcription.enqueue(session)
      assert job.worker == "VR.Workers.TranscriptionWorker"
    end

    test "recordings over 20 minutes go to the split worker", %{meeting: meeting} do
      session = uploaded_session(meeting, 25 * 60)

      assert {:ok, job} = Transcription.enqueue(session)
      assert job.worker == "VR.Workers.AudioSplitWorker"

      # Status flips to splitting as well
      assert Meetings.get_session(session.id).status == "splitting"
    end

    test "exactly 20 minutes is not split", %{meeting: meeting} do
      session = uploaded_session(meeting, 20 * 60)

      assert {:ok, job} = Transcription.enqueue(session)
      assert job.worker == "VR.Workers.TranscriptionWorker"
    end

    test "rejects sessions without audio", %{meeting: meeting} do
      {:ok, session} = Meetings.create_session(meeting)
      assert {:error, :no_audio} = Transcription.enqueue(session)
    end
  end

  describe "transcription worker" do
    test "transcribes and builds the speaker map", %{meeting: meeting, account: account} do
      session = uploaded_session(meeting)

      assert :ok =
               perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})

      done = Meetings.get_session(session.id)
      assert done.status == "completed"
      assert length(done.transcript["segments"]) == 5
      # Originals are kept so edits can be restored
      assert length(done.transcript["original_segments"]) == 5

      # Each speaker gets a default name
      assert map_size(done.speaker_map) == 3
      assert %{"name" => "Speaker 1"} = done.speaker_map["speaker_1"]

      _ = account
    end

    test "meters credits", %{meeting: meeting, account: account} do
      {:ok, _} = Credits.grant(account.id, 1000)
      session = uploaded_session(meeting, 600)

      :ok = perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})

      # 10 min × $0.016 = $0.16 → $0.16/$0.0015 = 106.67 → rounds up to 107
      [entry | _] = Credits.list_ledger(account.id)
      assert entry.source == "usage"
      assert entry.charge_domain == "stt"
      assert entry.charged_credits == 107
      assert Credits.balance(account.id) == 893
    end

    test "skips metering without a unit price but transcription still succeeds", %{meeting: meeting, account: account} do
      Config.delete("stt.cost_per_minute_usd")
      session = uploaded_session(meeting)

      assert :ok = perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})
      assert Meetings.get_session(session.id).status == "completed"
      assert Credits.list_ledger(account.id) == []
    end

    test "is not metered twice on retry", %{meeting: meeting, account: account} do
      {:ok, _} = Credits.grant(account.id, 1000)
      session = uploaded_session(meeting, 600)

      :ok = perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})
      balance_after_first = Credits.balance(account.id)

      # Run the same session again (worker retry scenario)
      :ok = perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})

      assert Credits.balance(account.id) == balance_after_first
    end

    test "meeting aggregates are refreshed", %{meeting: meeting} do
      session = uploaded_session(meeting, 600)

      :ok = perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})

      assert Meetings.get_meeting(meeting.id).total_duration_seconds == 600
    end

    test "cancels for a nonexistent session" do
      assert {:cancel, :session_not_found} =
               perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => "mrss_nope"})
    end

    test "cancels when there is no audio", %{meeting: meeting} do
      {:ok, session} = Meetings.create_session(meeting)

      assert {:cancel, :no_audio} =
               perform_job(VR.Workers.TranscriptionWorker, %{"session_id" => session.id})
    end
  end

  describe "audio utils" do
    test "split threshold" do
      refute Audio.needs_splitting?(20 * 60)
      assert Audio.needs_splitting?(20 * 60 + 1)
      refute Audio.needs_splitting?(nil)
    end

    test "MP3 detection" do
      assert Audio.mp3?("audio/mpeg")
      assert Audio.mp3?("audio/mp3")
      refute Audio.mp3?("audio/webm")
      refute Audio.mp3?(nil)
    end

    test "range labels" do
      assert Audio.range_label(0, 19 * 60) == "0:00~19:00"
      assert Audio.range_label(19 * 60, 19 * 60) == "19:00~38:00"
      assert Audio.range_label(0, 65) == "0:00~1:05"
    end
  end
end
