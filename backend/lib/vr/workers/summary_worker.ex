defmodule VR.Workers.SummaryWorker do
  @moduledoc """
  회의 하나를 요약한다.

  **출처: sisyphus** — sisyphus 는 n8n 웹훅을 때렸다.
  이 워커가 그 자리를 대신한다 ([04-pipeline.md](../../../docs/04-pipeline.md)).

  ## unique

  `meeting_id` 단위로 60초 unique. 세션이 여러 개면 전사가 끝날 때마다
  요약이 큐잉되는데, 마지막 하나만 돌면 된다.
  **`mode` 는 unique 키에서 뺀다** — 사용자가 [재요약] 을 눌렀는데
  auto 잡이 먼저 들어와 있다고 무시되면, 눌러도 아무 일이 없는 것처럼 보인다.
  대신 아래 `replace` 로 나중 것이 이긴다.
  """

  use Oban.Worker,
    queue: :summarize,
    max_attempts: 3,
    priority: 3,
    unique: [
      period: 60,
      fields: [:worker, :args],
      keys: [:meeting_id],
      states: :incomplete
    ],
    replace: [scheduled: [:args], available: [:args]]

  alias VR.Meetings
  alias VR.Summarize

  require Logger

  # LLM 호출 3분 + 폴백 2회 = 최악 10분
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    meeting_id = args["meeting_id"]
    mode = args["mode"] || "auto"

    Logger.info("[Summary] 시작: #{meeting_id} (#{mode}, 시도 #{attempt})")

    case Meetings.get_meeting(meeting_id) do
      nil ->
        {:cancel, :meeting_not_found}

      meeting ->
        run(meeting, mode, attempt)
    end
  end

  defp run(meeting, mode, attempt) do
    cond do
      # auto 는 이미 요약이 있으면 건드리지 않는다. 사용자가 고친 요약을 덮지 않기 위해서다.
      mode == "auto" and has_summary?(meeting) ->
        Logger.info("[Summary] 이미 요약이 있어 건너뜁니다: #{meeting.id}")
        :ok

      not Summarize.ready?() ->
        # 키가 없는 것은 재시도로 해결되지 않는다. 어드민이 넣어야 한다.
        Logger.warning("[Summary] 사용 가능한 LLM 제공자가 없습니다: #{meeting.id}")
        {:cancel, :no_provider}

      true ->
        generate(meeting, attempt)
    end
  end

  defp generate(meeting, attempt) do
    case Summarize.summarize(meeting, account_id: meeting.owner_id) do
      {:ok, updated} ->
        Logger.info("[Summary] 완료: #{meeting.id}")

        # 요약 본문은 담지 않는다 — 잠금화면에 회의 내용이 뜨면 곤란하다
        VR.Push.notify(
          meeting.owner_id,
          updated.title || "회의",
          "요약이 준비됐습니다.",
          url: "/go/meetings/#{meeting.id}",
          tag: "summary:#{meeting.id}"
        )

        :ok

      {:error, :no_transcript} ->
        # 전사가 없으면 요약할 것이 없다. 재시도해도 같다.
        {:cancel, :no_transcript}

      {:error, reason} ->
        Logger.error("[Summary] 실패: #{meeting.id} — #{inspect(reason)} (시도 #{attempt})")
        {:error, reason}
    end
  end

  defp has_summary?(%{summary_data: data}) when is_map(data) and map_size(data) > 0, do: true
  defp has_summary?(_), do: false
end
