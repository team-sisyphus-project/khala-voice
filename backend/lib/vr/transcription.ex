defmodule VR.Transcription do
  @moduledoc """
  전사 진입점 — 큐잉과 사용량 계량.

  실제 STT 호출은 `VR.Transcription.GoogleSTT`, 오디오 처리는
  `VR.Transcription.Audio` 가 한다. 여기는 그 둘을 도메인에 붙인다.
  """

  alias VR.Billing.Credits
  alias VR.Config
  alias VR.Meetings
  alias VR.Meetings.RecordingSession
  alias VR.Transcription.{Audio, GoogleSTT}
  alias VR.Workers.{AudioSplitWorker, TranscriptionWorker}

  require Logger

  @doc """
  세션 전사를 큐에 넣는다.

  20분을 넘으면 분할 워커로, 아니면 전사 워커로 보낸다.
  판단은 여기서 한 번만 한다 — 워커마다 하면 규칙이 갈라진다.
  """
  def enqueue(%RecordingSession{} = session) do
    cond do
      is_nil(session.audio_url) ->
        {:error, :no_audio}

      Audio.needs_splitting?(session.duration_seconds) ->
        {:ok, _} = Meetings.set_session_status(session, "splitting")

        %{session_id: session.id}
        |> AudioSplitWorker.new()
        |> Oban.insert()

      true ->
        %{session_id: session.id}
        |> TranscriptionWorker.new()
        |> Oban.insert()
    end
  end

  @doc "이 환경에서 전사가 가능한가. 어드민 대시보드가 쓴다."
  def ready? do
    GoogleSTT.ready?() and (GoogleSTT.dev_mode?() or Audio.available?())
  end

  @doc """
  전사 사용량을 계량한다.

  단가가 설정되지 않았으면 **계량하지 않고 넘어간다** —
  요금 설정이 덜 됐다고 전사를 실패시키지 않는다.
  """
  def charge(%RecordingSession{} = session, account_id) do
    with {:ok, cost} <- usage_cost(session) do
      Credits.charge_usage(account_id, cost,
        charge_domain: "stt",
        reason: "전사 #{minutes(session)}분",
        # 워커가 재시도돼도 두 번 기록되지 않는다
        idempotency_key: "stt:#{session.id}",
        pricing_snapshot: %{
          "duration_seconds" => session.duration_seconds,
          "minutes" => minutes(session),
          "cost_per_minute_usd" => Config.fetch("stt.cost_per_minute_usd")
        }
      )
    else
      {:error, :no_pricing} ->
        Logger.info("[Transcription] STT 단가가 없어 계량을 건너뜁니다: #{session.id}")
        {:ok, :not_metered}

      error ->
        error
    end
  end

  defp usage_cost(session) do
    case Config.fetch("stt.cost_per_minute_usd") do
      nil ->
        {:error, :no_pricing}

      "" ->
        {:error, :no_pricing}

      rate ->
        case Decimal.parse(rate) do
          {decimal, _} -> {:ok, Decimal.mult(decimal, minutes(session))}
          :error -> {:error, :no_pricing}
        end
    end
  end

  # 분 단위 올림. 30초를 써도 1분으로 센다 — 제공자도 그렇게 청구한다.
  defp minutes(%RecordingSession{duration_seconds: seconds}) when is_integer(seconds),
    do: max(ceil(seconds / 60), 1)

  defp minutes(_), do: 1
end
