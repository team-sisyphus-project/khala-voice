defmodule VR.Summarize.Normalizer do
  @moduledoc """
  LLM 응답을 `summary_data` 로 정규화한다.

  **출처: sisyphus** — 스키마 자체는 n8n `autosquad-meeting-summary.json` 의
  출력 규약을 그대로 따른다. 검증 로직은 이 앱에서 새로 쓴다
  (n8n 은 모델 출력을 그대로 흘려보냈다).

  ## 왜 검증하나

  구조화 출력을 걸어도 모델은 **`source` 를 지어낸다.** 있지도 않은 시각,
  원문과 다른 인용, 다른 세션의 id. 그대로 저장하면 요약 항목을 눌렀을 때
  엉뚱한 지점으로 점프한다 — 사용자는 요약 전체를 못 믿게 된다.

  그래서 실제 전사와 대조한다.

  - `session_id` 가 이번 요약에 들어간 세션이 아니면 → `source` 를 버린다
  - `time_label` 위치에 발화가 없으면 → `source` 를 버린다
  - `quote` 가 그 지점 발화와 많이 다르면 → **인용만** 실제 발화로 교정한다

  **항목 자체는 남긴다.** 근거를 못 찾았다고 결정사항을 지우면
  요약이 조용히 비어버린다. 점프만 포기하는 편이 낫다.
  """

  alias VR.Summarize.Serializer

  @max_items 50
  @max_topics 5

  @doc """
  모델 출력(map)을 `summary_data` 로 만든다.

  `sessions` 는 이번 요약에 들어간 세션들. `source` 대조에 쓴다.
  """
  def normalize(raw, sessions) when is_map(raw) do
    index = build_index(sessions)

    %{
      "one_liner" => text(raw["one_liner"]),
      "decisions" => sourced_list(raw["decisions"], "text", index),
      "action_items" => action_items(raw["action_items"], index),
      "facts" => string_list(raw["facts"]),
      "open_questions" => string_list(raw["open_questions"]),
      "next_steps" => string_list(raw["next_steps"]),
      "key_topics" => raw["key_topics"] |> string_list() |> Enum.take(@max_topics)
    }
  end

  def normalize(_, _), do: nil

  @doc """
  코드펜스에 감싸여 오거나 앞뒤에 말이 붙어 와도 JSON 을 건져낸다.

  구조화 출력을 지원하지 않는 모델·엔드포인트가 섞여 있어서 필요하다.
  """
  def decode(body) when is_binary(body) do
    trimmed = String.trim(body)

    with :error <- try_decode(trimmed),
         :error <- try_decode(strip_fence(trimmed)),
         :error <- try_decode(slice_braces(trimmed)) do
      {:error, :invalid_json}
    end
  end

  def decode(_), do: {:error, :invalid_json}

  # ── source 대조 ──────────────────────────────────────────

  @doc """
  `source` 를 실제 전사와 대조한다. 못 찾으면 `nil`.

  반환된 `source` 에는 `start_ms` 가 붙는다 — 프런트가 시각을 다시
  파싱하지 않고 바로 그 지점으로 점프할 수 있게.
  """
  def verify_source(source, index) when is_map(source) do
    session_id = text(source["session_id"])
    start_ms = Serializer.parse_time_label(source["time_label"])

    with true <- session_id != "",
         true <- not is_nil(start_ms),
         %{} = segment <- Map.get(index, {session_id, start_ms}) do
      %{
        "session_id" => session_id,
        "speaker" => segment.speaker,
        "time_label" => Serializer.time_label(start_ms),
        # 인용은 모델 말이 아니라 실제 발화를 신뢰한다
        "quote" => segment.text,
        "start_ms" => start_ms
      }
    else
      _ -> nil
    end
  end

  def verify_source(_, _), do: nil

  @doc "세션들의 발화를 `{session_id, start_ms}` 로 찾을 수 있게 편다."
  def build_index(sessions) do
    for session <- sessions,
        segment <- segments(session.transcript),
        into: %{} do
      start_ms = segment["start_ms"] || 0

      # 초 단위로 자른다 — 라벨이 HH:MM:SS 라 밀리초는 어차피 왕복하며 날아간다
      key = {session.id, div(start_ms, 1000) * 1000}

      {key,
       %{
         speaker: speaker_name(session.speaker_map || %{}, segment["speaker"]),
         text: String.trim(segment["text"] || ""),
         start_ms: start_ms
       }}
    end
  end

  # ── 내부 ─────────────────────────────────────────────────

  defp sourced_list(items, text_key, index) when is_list(items) do
    items
    |> Enum.take(@max_items)
    |> Enum.map(fn item ->
      if is_map(item) do
        body = text(item[text_key])

        if body == "",
          do: nil,
          else: %{text_key => body, "source" => verify_source(item["source"], index)}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp sourced_list(_, _, _), do: []

  defp action_items(items, index) when is_list(items) do
    items
    |> Enum.take(@max_items)
    |> Enum.map(fn item ->
      if is_map(item) do
        what = text(item["what"])

        if what == "" do
          nil
        else
          %{
            "who" => text(item["who"]),
            "what" => what,
            "due" => text(item["due"]),
            "source" => verify_source(item["source"], index)
          }
        end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp action_items(_, _), do: []

  defp string_list(values) when is_list(values) do
    values
    |> Enum.take(@max_items)
    |> Enum.map(&text/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(_), do: []

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_number(value), do: to_string(value)
  defp text(_), do: ""

  defp segments(%{"segments" => segments}) when is_list(segments), do: segments
  defp segments(_), do: []

  defp speaker_name(speaker_map, key) do
    case speaker_map[key] do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _ -> key || ""
    end
  end

  defp try_decode(nil), do: :error

  defp try_decode(candidate) do
    case Jason.decode(candidate) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp strip_fence(body) do
    case Regex.run(~r/```(?:json)?\s*(.+?)\s*```/s, body) do
      [_, inner] -> inner
      _ -> nil
    end
  end

  # 바이트 오프셋으로 자른다. `String.slice/2` 는 글자 단위라
  # 앞에 한글이 섞이면 엉뚱한 곳을 자른다.
  defp slice_braces(body) do
    with start when start != nil <- index_of(body, "{"),
         finish when finish != nil <- last_index_of(body, "}"),
         true <- finish > start do
      binary_part(body, start, finish - start + 1)
    else
      _ -> nil
    end
  end

  defp index_of(body, char) do
    case :binary.match(body, char) do
      {position, _} -> position
      :nomatch -> nil
    end
  end

  defp last_index_of(body, char) do
    case :binary.matches(body, char) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
