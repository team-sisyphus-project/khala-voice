defmodule VR.Summarize do
  @moduledoc """
  AI summary entry point — queueing, generation, and usage metering.

  **Origin: sisyphus** n8n `autosquad-meeting-summary.json`.
  sisyphus delegated this to an n8n workflow, but this app calls the LLM
  directly (user requirement: remove n8n — [14-provenance.md](../../docs/14-provenance.md)).

  ## Modes

  | Mode | Trigger | Behavior |
  |---|---|---|
  | `auto` | automatic when transcription completes | skipped if a summary already exists |
  | `retry` | user clicks [Re-summarize] | ignores the auto guard and regenerates |
  """

  import Ecto.Query, warn: false

  alias VR.Billing.Credits
  alias VR.Config
  alias VR.Meetings
  alias VR.Meetings.Meeting
  alias VR.Repo
  alias VR.Summarize.{LLM, LlmProviders, Normalizer, Prompt, Serializer}
  alias VR.Workers.SummaryWorker

  require Logger

  @million Decimal.new(1_000_000)

  @doc """
  Enqueues a summary job.

  The job is unique per `meeting_id`, so it never runs twice concurrently.
  """
  def enqueue(%Meeting{} = meeting, mode \\ "auto") do
    %{meeting_id: meeting.id, mode: mode}
    |> SummaryWorker.new()
    |> Oban.insert()
  end

  @doc "Whether summarization is available in this environment. Used by the admin dashboard."
  def ready?, do: dev_mode?() or LLM.ready?()

  @doc """
  Dev mode. When enabled, produces a mock summary without calling the LLM.

  **Origin: sisyphus** — same idea as its `stt.dev_mode`:
  the whole UI must be verifiable without credentials.
  """
  def dev_mode? do
    case Config.fetch("llm.dev_mode") do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  @doc """
  Generates and stores a meeting summary.

  On failure it records `last_summary_error` and **leaves the existing
  `summary_data` untouched** — a failed re-summarize must not destroy a
  perfectly good summary.
  """
  def summarize(%Meeting{} = meeting, opts \\ []) do
    sessions = summarizable_sessions(meeting)

    case Serializer.serialize(sessions) do
      %{text: ""} ->
        {:error, :no_transcript}

      %{chunks: chunks, included_session_ids: included, skipped_session_ids: skipped} ->
        with {:ok, result, raw} <- run(meeting, chunks) do
          summary_data =
            raw
            |> Normalizer.normalize(sessions)
            |> Map.merge(%{
              "language" => language(meeting, sessions),
              "provider" => result.provider,
              "model" => result.model,
              "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "included_session_ids" => included,
              "skipped_session_ids" => skipped,
              # How many chunks the summary was split into. 1 means it fit in one call.
              # The UI must be able to say "this summary was generated in parts".
              "chunk_count" => length(chunks)
            })

          # **Save first.** Even if metering blows up, the summary we already
          # generated is not lost. Same order as the transcription worker
          # (finish the work, then price it).
          saved =
            Meetings.update_summary(meeting, %{
              summary_data: summary_data,
              summary: summary_data["one_liner"],
              last_summary_error: nil
            })

          charge(meeting, result, opts[:account_id])

          saved
        else
          {:error, reason} ->
            record_failure(meeting, reason)
            {:error, reason}
        end
    end
  end

  @doc "Sessions eligible for summarization — only those with a transcript."
  def summarizable_sessions(%Meeting{} = meeting) do
    meeting = Repo.preload(meeting, :recording_sessions)

    meeting.recording_sessions
    |> Enum.reject(& &1.deleted_at)
    |> Enum.sort_by(& &1.session_index)
  end

  @doc """
  Converts LLM token usage into credits and records the charge.

  **Origin: devkanban** `MS.Meters.UsageRecorder.price_tokens/3` —
  follows the same formula: per-million-token unit price plus a margin.

  If there is no pricing, **metering is skipped entirely.** Same rule as STT.
  """
  def charge(%Meeting{} = meeting, result, account_id) do
    account_id = account_id || meeting.owner_id

    with {:ok, pricing} <- pricing_for(result.provider),
         {:ok, cost} <- token_cost(result.usage, pricing) do
      Credits.charge_usage(account_id, cost.usage_cost_usd,
        charge_domain: "llm",
        reason: "AI summary (#{result.model})",
        # Even if the worker retries, the charge is not recorded twice
        idempotency_key: "llm:#{meeting.id}:#{result.model}",
        pricing_snapshot: %{
          "provider" => result.provider,
          "model" => result.model,
          "input_tokens" => result.usage.input_tokens,
          "output_tokens" => result.usage.output_tokens,
          "input_price_usd_per_1m" => to_string(pricing.input_price_usd_per_1m),
          "output_price_usd_per_1m" => to_string(pricing.output_price_usd_per_1m),
          "margin_rate" => to_string(pricing.margin_rate),
          "base_usage_cost_usd" => to_string(cost.base_usage_cost_usd),
          "margin_amount_usd" => to_string(cost.margin_amount_usd)
        }
      )
    else
      {:error, :no_pricing} ->
        Logger.info("[Summarize] No LLM pricing configured; skipping metering: #{meeting.id}")
        {:ok, :not_metered}

      error ->
        Logger.warning("[Summarize] Metering failed: #{inspect(error)}")
        error
    end
  end

  @doc """
  Token cost calculation. **Origin: devkanban** `price_tokens/3`.

      (input tokens x price/1M + output tokens x price/1M) x (1 + margin)
  """
  def token_cost(usage, pricing) do
    input = decimal(pricing.input_price_usd_per_1m)
    output = decimal(pricing.output_price_usd_per_1m)

    if Decimal.eq?(input, 0) and Decimal.eq?(output, 0) do
      {:error, :no_pricing}
    else
      input_cost =
        input |> Decimal.mult(Decimal.new(usage.input_tokens)) |> Decimal.div(@million)

      output_cost =
        output |> Decimal.mult(Decimal.new(usage.output_tokens)) |> Decimal.div(@million)

      base = Decimal.add(input_cost, output_cost)
      margin = Decimal.mult(base, decimal(pricing.margin_rate))

      {:ok,
       %{
         base_usage_cost_usd: base,
         margin_amount_usd: margin,
         usage_cost_usd: Decimal.add(base, margin)
       }}
    end
  end

  # ── Internal ─────────────────────────────────────────────

  @doc false
  # Generates the summary. A single chunk means one call; multiple chunks are
  # **summarized separately and then merged**.
  #
  # ## Why we do not truncate
  #
  # Truncating makes the tail of the meeting silently vanish from the summary.
  # For meeting minutes this is the worst failure mode — the summary looks fine
  # but every decision from the last 30 minutes is simply missing. sisyphus
  # truncated at 60,000 characters here (`meetings.ex:710`).
  #
  # ## Merge rules
  #
  # Every chunk is summarized with the **same schema**. Each item carries its
  # source (session_id and timestamp), so most sections merge by simple
  # concatenation. Only `one_liner` has to describe the whole meeting in one
  # sentence, so we make one extra call for it at the end.
  defp run(meeting, [single]) do
    with {:ok, result} <- generate(meeting, single),
         {:ok, raw} <- Normalizer.decode(result.body) do
      {:ok, result, raw}
    end
  end

  defp run(meeting, chunks) do
    Logger.info("[Summarize] #{meeting.id}: summarizing in #{length(chunks)} chunks")

    # If any chunk fails, fail the whole run. Saving a partial summary would
    # leave it looking finished, and auto-summarize would then skip regeneration
    # because a summary "already exists".
    chunks
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case run(meeting, [chunk]) do
        {:ok, result, raw} -> {:cont, {:ok, [{result, raw} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} ->
        {:error, reason}

      {:ok, parts} ->
        parts = Enum.reverse(parts)
        merged = merge(Enum.map(parts, &elem(&1, 1)))

        # Cost is the sum of every call. Splitting must not make it cheaper.
        total = sum_usage(Enum.map(parts, &elem(&1, 0)))

        case one_liner(meeting, merged) do
          {:ok, line, extra} ->
            {:ok, sum_usage([total, extra]), Map.put(merged, "one_liner", line)}

          # Even if the one-liner call fails, keep the rest of the summary —
          # fall back to the first chunk's one-liner.
          :error ->
            {:ok, total, merged}
        end
    end
  end

  # Items carry their sources, so concatenation is enough. Only plain string
  # lists get deduplicated.
  defp merge(raws) do
    %{
      "one_liner" =>
        raws |> Enum.map(& &1["one_liner"]) |> Enum.reject(&blank?/1) |> List.first(),
      "decisions" => Enum.flat_map(raws, &List.wrap(&1["decisions"])),
      "action_items" => Enum.flat_map(raws, &List.wrap(&1["action_items"])),
      "facts" => merge_strings(raws, "facts"),
      "open_questions" => merge_strings(raws, "open_questions"),
      "next_steps" => merge_strings(raws, "next_steps"),
      "key_topics" => merge_strings(raws, "key_topics")
    }
  end

  defp merge_strings(raws, key) do
    raws
    |> Enum.flat_map(&List.wrap(&1[key]))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  # Combines the per-chunk one-liners into a single one-liner for the whole meeting.
  defp one_liner(_meeting, %{"one_liner" => only}) when is_binary(only), do: {:ok, only, nil}

  defp one_liner(meeting, merged) do
    lines =
      merged
      |> Map.get("key_topics", [])
      |> Enum.take(20)
      |> Enum.join(", ")

    case generate(meeting, "These are the key topics of a meeting. Summarize the entire meeting in one sentence.\n\n#{lines}") do
      {:ok, result} ->
        case Normalizer.decode(result.body) do
          {:ok, %{"one_liner" => line}} when is_binary(line) -> {:ok, line, result}
          _ -> :error
        end

      {:error, _} ->
        :error
    end
  end

  # Sums token usage across multiple calls. Skips nil entries.
  defp sum_usage(results) do
    results
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(fn result, acc ->
      %{
        acc
        | input_tokens: (acc.input_tokens || 0) + (result.input_tokens || 0),
          output_tokens: (acc.output_tokens || 0) + (result.output_tokens || 0)
      }
    end)
  end

  defp generate(meeting, text) do
    if dev_mode?() do
      {:ok, VR.Summarize.Dev.result(meeting, text)}
    else
      LLM.complete(Prompt.system(), Prompt.user(meeting.title, text), Prompt.schema())
    end
  end

  defp pricing_for(provider_name) do
    case Enum.find(LlmProviders.list_all(), &(&1.provider == provider_name)) do
      nil -> {:error, :no_pricing}
      provider -> {:ok, provider}
    end
  end

  # Uses the language chosen at recording time. It only lives in session metadata.
  defp language(_meeting, sessions) do
    sessions
    |> Enum.find_value(fn session -> get_in(session.metadata || %{}, ["language"]) end)
    |> case do
      nil -> "ko"
      # STT uses locales like `ko-KR`, but summary metadata keeps only the language code
      locale -> locale |> String.split("-") |> List.first()
    end
  end

  defp record_failure(meeting, reason) do
    Meetings.update_summary(meeting, %{
      last_summary_error: %{
        "reason" => inspect(reason),
        "at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  defp decimal(nil), do: Decimal.new(0)
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, _} -> parsed
      :error -> Decimal.new(0)
    end
  end
end
