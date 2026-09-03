defmodule VR.Summarize.Serializer do
  @moduledoc """
  Serializes a transcript into the LLM input string.

  **Origin: sisyphus** n8n `autosquad-meeting-summary.json` — this format is
  a **contract shared with the prompt**. The prompt parses these labels to
  extract `source.session_id`, `source.speaker`, and `source.time_label`.
  Change the format and clicking a summary item to jump into the audio breaks
  wholesale.

      [<session_id>|<speaker_name>|<HH:MM:SS>] utterance text

  ## Delimiters are stripped from speaker names

  If a `|` or `]` sneaks into a name, the prompt splits the label incorrectly.
  Users can rename speakers freely, so we sanitize here.
  """

  alias VR.Meetings.RecordingSession

  @doc """
  Transcript length (in characters) for a single LLM call.

  Beyond this limit we **split and summarize in parts instead of truncating**
  (the map-reduce in `VR.Summarize`). Truncating makes the tail silently
  disappear from the summary, and the user has no way to notice.

  **sisyphus truncated here** — `String.slice(0, 60_000)` at `meetings.ex:710`.
  A two-hour meeting runs around 80k characters with labels, so the last third
  never made it into the summary, and the summary still looked fine. (The
  "nicely processed in 20-minute chunks" people remember was **transcription**,
  not summarization — audio was split because of Google STT BatchRecognize's
  20-minute limit, and that behavior is ported as-is in `AudioSplitWorker`.)
  """
  @chunk_chars 60_000

  def chunk_chars, do: @chunk_chars

  @doc """
  Builds a single transcript text from a list of sessions.

  Sessions without a transcript are skipped. Which sessions were included or
  skipped must be recorded in `summary_data`, so both lists are returned.
  """
  def serialize(sessions) when is_list(sessions) do
    {included, skipped} =
      sessions
      |> Enum.sort_by(& &1.session_index)
      |> Enum.split_with(&has_transcript?/1)

    lines = Enum.flat_map(included, &session_lines/1)

    %{
      text: Enum.join(lines, "\n"),
      chunks: chunk(lines),
      included_session_ids: Enum.map(included, & &1.id),
      skipped_session_ids: Enum.map(skipped, & &1.id)
    }
  end

  @doc """
  Splits utterance lines into chunks that fit in one call.

  **Splits only at line boundaries.** Cutting mid-line leaves an utterance with
  a broken `[session|speaker|time]` label; the prompt then cites it and the
  summary ends up with wrong sources — clicking the item plays the wrong spot.

  A single line that exceeds the limit by itself (an abnormally long utterance)
  gets its own chunk. Better to let the model condense it than to cut it.
  """
  def chunk(lines) when is_list(lines) do
    lines
    |> Enum.reduce({[], [], 0}, fn line, {done, current, size} ->
      len = String.length(line) + 1

      cond do
        current == [] -> {done, [line], len}
        size + len > @chunk_chars -> {[Enum.reverse(current) | done], [line], len}
        true -> {done, [line | current], size + len}
      end
    end)
    |> then(fn {done, current, _} ->
      done = if current == [], do: done, else: [Enum.reverse(current) | done]

      done
      |> Enum.reverse()
      |> Enum.map(&Enum.join(&1, "\n"))
    end)
  end

  @doc "Utterance lines for one session."
  def session_lines(%RecordingSession{} = session) do
    speaker_map = session.speaker_map || %{}

    session.transcript
    |> segments()
    |> Enum.map(fn segment ->
      speaker = speaker_name(speaker_map, segment["speaker"])
      label = time_label(segment["start_ms"])
      text = String.trim(segment["text"] || "")

      "[#{session.id}|#{speaker}|#{label}] #{text}"
    end)
    |> Enum.reject(&String.ends_with?(&1, "] "))
  end

  @doc """
  `HH:MM:SS`. **Always includes the hours position** — the prompt expects three parts.
  """
  def time_label(ms) when is_number(ms) do
    total = max(0, trunc(ms / 1000))
    h = div(total, 3600)
    m = div(rem(total, 3600), 60)
    s = rem(total, 60)

    [h, m, s]
    |> Enum.map(&(&1 |> Integer.to_string() |> String.pad_leading(2, "0")))
    |> Enum.join(":")
  end

  def time_label(_), do: "00:00:00"

  @doc "`HH:MM:SS` -> milliseconds. Used to locate the audio position from a summary's `time_label`."
  def parse_time_label(label) when is_binary(label) do
    case String.split(String.trim(label), ":") do
      [h, m, s] -> to_ms(h, m, s)
      [m, s] -> to_ms("0", m, s)
      _ -> nil
    end
  end

  def parse_time_label(_), do: nil

  # ── Internal ─────────────────────────────────────────────

  defp to_ms(h, m, s) do
    with {hh, ""} <- Integer.parse(h),
         {mm, ""} <- Integer.parse(m),
         {ss, ""} <- Integer.parse(s) do
      (hh * 3600 + mm * 60 + ss) * 1000
    else
      _ -> nil
    end
  end

  defp has_transcript?(%RecordingSession{} = session), do: segments(session.transcript) != []

  defp segments(%{"segments" => segments}) when is_list(segments), do: segments
  defp segments(_), do: []

  # If label delimiters sneak into a name, the prompt splits the label incorrectly
  defp speaker_name(speaker_map, key) do
    name =
      case speaker_map[key] do
        %{"name" => name} when is_binary(name) and name != "" -> name
        _ -> fallback_name(key)
      end

    name
    |> String.replace(~r/[\|\[\]]/, " ")
    |> String.trim()
    |> case do
      "" -> fallback_name(key)
      cleaned -> cleaned
    end
  end

  defp fallback_name(key) when is_binary(key) do
    case Regex.run(~r/^speaker[_-]?(\d+)$/i, key) do
      [_, n] -> "Speaker #{n}"
      _ -> key
    end
  end

  defp fallback_name(_), do: "Speaker"
end
