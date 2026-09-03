defmodule VR.Summarize.Normalizer do
  @moduledoc """
  Normalizes the LLM response into `summary_data`.

  **Origin: sisyphus** — the schema itself follows the output contract of the
  n8n `autosquad-meeting-summary.json` workflow verbatim. The validation logic
  is new in this app (n8n passed model output straight through).

  ## Why validate

  Even with structured output enabled, the model **fabricates `source`.**
  Timestamps that do not exist, quotes that differ from the original, ids from
  other sessions. Store that as-is and clicking a summary item jumps to the
  wrong spot — and the user stops trusting the whole summary.

  So we check it against the actual transcript.

  - `session_id` is not one of the sessions in this summary → drop the `source`
  - no utterance at the `time_label` position → drop the `source`
  - `quote` differs substantially from the utterance there → correct **only the quote** to the actual utterance

  **The item itself is kept.** Deleting a decision just because we could not
  find its evidence would silently empty the summary. Better to give up only
  the jump.
  """

  alias VR.Summarize.Serializer

  @max_items 50
  @max_topics 5

  @doc """
  Builds `summary_data` from the model output (a map).

  `sessions` are the sessions included in this summary, used for `source` verification.
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
  Salvages JSON even when it arrives wrapped in code fences or surrounded by prose.

  Needed because some models and endpoints in the mix do not support structured output.
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

  # ── source verification ─────────────────────────────────

  @doc """
  Verifies a `source` against the actual transcript. Returns `nil` if not found.

  The returned `source` carries a `start_ms` — so the frontend can jump
  straight to that spot without re-parsing the timestamp.
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
        # For the quote, trust the actual utterance, not the model's words
        "quote" => segment.text,
        "start_ms" => start_ms
      }
    else
      _ -> nil
    end
  end

  def verify_source(_, _), do: nil

  @doc "Flattens session utterances into a lookup keyed by `{session_id, start_ms}`."
  def build_index(sessions) do
    for session <- sessions,
        segment <- segments(session.transcript),
        into: %{} do
      start_ms = segment["start_ms"] || 0

      # Truncate to whole seconds — labels are HH:MM:SS, so milliseconds are lost in the round trip anyway
      key = {session.id, div(start_ms, 1000) * 1000}

      {key,
       %{
         speaker: speaker_name(session.speaker_map || %{}, segment["speaker"]),
         text: String.trim(segment["text"] || ""),
         start_ms: start_ms
       }}
    end
  end

  # ── Internal ─────────────────────────────────────────────

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

  # Slice by byte offset. `String.slice/2` works on characters, so multibyte
  # text (e.g. Korean) before the braces would make it cut in the wrong place.
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
