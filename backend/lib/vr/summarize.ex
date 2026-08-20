defmodule VR.Summarize do
  @moduledoc """
  AI 요약 진입점 — 큐잉 · 생성 · 사용량 계량.

  **출처: sisyphus** n8n `autosquad-meeting-summary.json`.
  sisyphus 는 n8n 워크플로에 위임했지만 이 앱은 직접 호출한다
  (사용자 요구: n8n 제거 — [14-provenance.md](../../docs/14-provenance.md)).

  ## 모드

  | 모드 | 트리거 | 동작 |
  |---|---|---|
  | `auto` | 전사 완료 시 자동 | 이미 요약이 있으면 건너뛴다 |
  | `retry` | 사용자가 [재요약] | auto 가드를 무시하고 다시 만든다 |
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
  요약을 큐에 넣는다.

  `meeting_id` 단위 unique 잡이라 중복 실행되지 않는다.
  """
  def enqueue(%Meeting{} = meeting, mode \\ "auto") do
    %{meeting_id: meeting.id, mode: mode}
    |> SummaryWorker.new()
    |> Oban.insert()
  end

  @doc "이 환경에서 요약이 가능한가. 어드민 대시보드가 쓴다."
  def ready?, do: dev_mode?() or LLM.ready?()

  @doc """
  개발 모드. 켜면 LLM 을 부르지 않고 목 요약을 만든다.

  **출처: sisyphus** 의 `stt.dev_mode` 와 같은 발상 —
  자격증명 없이 전체 UI 를 확인할 수 있어야 한다.
  """
  def dev_mode? do
    case Config.fetch("llm.dev_mode") do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  @doc """
  회의 요약을 만들어 저장한다.

  실패하면 `last_summary_error` 에 남기고 **기존 `summary_data` 는 건드리지 않는다** —
  재요약이 실패했다고 멀쩡하던 요약을 잃으면 안 된다.
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
              # 몇 덩어리로 나눠 요약했는가. 1 이면 한 번에 들어간 것이다.
              # 화면이 "이 요약은 나눠서 만들어졌다"를 말할 수 있어야 한다.
              "chunk_count" => length(chunks)
            })

          # **저장이 먼저다.** 계량이 터져도 이미 만든 요약은 잃지 않는다.
          # 전사 워커와 같은 순서다 (일을 끝내고 나서 값을 매긴다).
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

  @doc "요약 대상 세션 — 전사가 있는 것만."
  def summarizable_sessions(%Meeting{} = meeting) do
    meeting = Repo.preload(meeting, :recording_sessions)

    meeting.recording_sessions
    |> Enum.reject(& &1.deleted_at)
    |> Enum.sort_by(& &1.session_index)
  end

  @doc """
  LLM 토큰 사용량을 크레딧으로 환산해 기록한다.

  **출처: devkanban** `MS.Meters.UsageRecorder.price_tokens/3` —
  백만 토큰당 단가에 마진을 가산하는 계산식을 그대로 따른다.

  단가가 없으면 **계량하지 않고 넘어간다.** STT 와 같은 규칙이다.
  """
  def charge(%Meeting{} = meeting, result, account_id) do
    account_id = account_id || meeting.owner_id

    with {:ok, pricing} <- pricing_for(result.provider),
         {:ok, cost} <- token_cost(result.usage, pricing) do
      Credits.charge_usage(account_id, cost.usage_cost_usd,
        charge_domain: "llm",
        reason: "AI 요약 (#{result.model})",
        # 워커가 재시도돼도 두 번 기록되지 않는다
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
        Logger.info("[Summarize] LLM 단가가 없어 계량을 건너뜁니다: #{meeting.id}")
        {:ok, :not_metered}

      error ->
        Logger.warning("[Summarize] 계량 실패: #{inspect(error)}")
        error
    end
  end

  @doc """
  토큰 단가 계산. **출처: devkanban** `price_tokens/3`.

      (입력토큰 × 단가/1M + 출력토큰 × 단가/1M) × (1 + 마진)
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

  # ── 내부 ─────────────────────────────────────────────────

  @doc false
  # 요약을 만든다. 덩어리가 하나면 한 번 부르고, 여럿이면 **나눠 요약한 뒤 합친다**.
  #
  # ## 왜 자르지 않나
  #
  # 자르면 뒷부분이 요약에서 조용히 사라진다. 회의록에서 이건 최악이다 —
  # 요약은 멀쩡해 보이는데 마지막 30분의 결정사항이 통째로 없다. sisyphus 는
  # 여기서 60,000자에 잘랐다(`meetings.ex:710`).
  #
  # ## 합치는 규칙
  #
  # 각 덩어리는 **같은 스키마**로 요약된다. 항목마다 출처(session_id · 시각)를
  # 들고 있어서 대부분은 이어 붙이면 끝난다. `one_liner` 만 회의 전체를 한 문장으로
  # 말해야 해서 마지막에 한 번 더 부른다.
  defp run(meeting, [single]) do
    with {:ok, result} <- generate(meeting, single),
         {:ok, raw} <- Normalizer.decode(result.body) do
      {:ok, result, raw}
    end
  end

  defp run(meeting, chunks) do
    Logger.info("[Summarize] #{meeting.id}: #{length(chunks)}덩어리로 나눠 요약한다")

    # 덩어리 하나가 실패하면 통째로 실패시킨다. 일부만 넣은 요약을 저장하면
    # 그게 완성본으로 남고, 자동 요약은 "이미 있음"으로 다시 만들지 않는다.
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

        # 비용은 모든 호출의 합이다. 나눠 불렀다고 덜 받으면 안 된다.
        total = sum_usage(Enum.map(parts, &elem(&1, 0)))

        case one_liner(meeting, merged) do
          {:ok, line, extra} ->
            {:ok, sum_usage([total, extra]), Map.put(merged, "one_liner", line)}

          # 한 문장 만들기에 실패해도 나머지 요약은 살린다 — 첫 덩어리의 것을 쓴다.
          :error ->
            {:ok, total, merged}
        end
    end
  end

  # 항목은 출처를 들고 있어 이어 붙이면 된다. 글자 목록만 중복을 지운다.
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

  # 덩어리별 한 문장을 모아 회의 전체의 한 문장을 만든다.
  defp one_liner(_meeting, %{"one_liner" => only}) when is_binary(only), do: {:ok, only, nil}

  defp one_liner(meeting, merged) do
    lines =
      merged
      |> Map.get("key_topics", [])
      |> Enum.take(20)
      |> Enum.join(", ")

    case generate(meeting, "다음은 한 회의의 주요 주제다. 회의 전체를 한 문장으로 요약하라.\n\n#{lines}") do
      {:ok, result} ->
        case Normalizer.decode(result.body) do
          {:ok, %{"one_liner" => line}} when is_binary(line) -> {:ok, line, result}
          _ -> :error
        end

      {:error, _} ->
        :error
    end
  end

  # 호출이 여럿이면 토큰을 더한다. nil 은 건너뛴다.
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

  # 녹음할 때 고른 언어를 그대로 쓴다. 세션 메타데이터에만 있다.
  defp language(_meeting, sessions) do
    sessions
    |> Enum.find_value(fn session -> get_in(session.metadata || %{}, ["language"]) end)
    |> case do
      nil -> "ko"
      # STT 는 `ko-KR` 을 쓰지만 요약 메타에는 언어 코드만 남긴다
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
