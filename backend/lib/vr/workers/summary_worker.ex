defmodule VR.Workers.SummaryWorker do
  @moduledoc """
  Summarizes one meeting.

  **Source: sisyphus** — sisyphus hit an n8n webhook.
  This worker takes its place ([04-pipeline.md](../../../docs/04-pipeline.md)).

  ## unique

  60-second unique per `meeting_id`. With multiple sessions, a summary is
  enqueued each time a transcription finishes, but only the last one needs to run.
  **`mode` is excluded from the unique key** — if the user pressed [Re-summarize]
  but the job were ignored because an auto job was already queued, the button
  would appear to do nothing. Instead, `replace` below lets the later one win.
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

  # 3 minutes per LLM call + 2 fallbacks = 10 minutes worst case
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    meeting_id = args["meeting_id"]
    mode = args["mode"] || "auto"

    Logger.info("[Summary] started: #{meeting_id} (#{mode}, attempt #{attempt})")

    case Meetings.get_meeting(meeting_id) do
      nil ->
        {:cancel, :meeting_not_found}

      meeting ->
        run(meeting, mode, attempt)
    end
  end

  defp run(meeting, mode, attempt) do
    cond do
      # auto never touches an existing summary, to avoid overwriting one the
      # user has edited.
      mode == "auto" and has_summary?(meeting) ->
        Logger.info("[Summary] summary already exists; skipping: #{meeting.id}")
        :ok

      not Summarize.ready?() ->
        # A missing key is not fixed by retrying. An admin has to provide it.
        Logger.warning("[Summary] no usable LLM provider: #{meeting.id}")
        {:cancel, :no_provider}

      true ->
        generate(meeting, attempt)
    end
  end

  defp generate(meeting, attempt) do
    case Summarize.summarize(meeting, account_id: meeting.owner_id) do
      {:ok, updated} ->
        Logger.info("[Summary] done: #{meeting.id}")

        # The summary body is not included — meeting contents must not appear
        # on a lock screen
        VR.Push.notify(
          meeting.owner_id,
          updated.title || "Meeting",
          "Your summary is ready.",
          url: "/go/meetings/#{meeting.id}",
          tag: "summary:#{meeting.id}"
        )

        :ok

      {:error, :no_transcript} ->
        # Without a transcript there is nothing to summarize. Retrying changes nothing.
        {:cancel, :no_transcript}

      {:error, reason} ->
        Logger.error("[Summary] failed: #{meeting.id} — #{inspect(reason)} (attempt #{attempt})")
        {:error, reason}
    end
  end

  defp has_summary?(%{summary_data: data}) when is_map(data) and map_size(data) > 0, do: true
  defp has_summary?(_), do: false
end
