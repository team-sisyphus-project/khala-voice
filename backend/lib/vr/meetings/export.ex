defmodule VR.Meetings.Export do
  @moduledoc """
  Meeting-notes Markdown export.

  **Source: sisyphus** — `exportTranscriptMarkdown()` in `assets/webapp/meeting-recorder.js`.
  The format is used as a reference, with the following changes.

  | sisyphus | this app | why |
  |---|---|---|
  | Client builds a Blob | **Server rendering** | Originally desktop produced `.md` and mobile `.txt`. Keep one implementation |
  | Absolute wall-clock times | **Relative `HH:MM:SS` within the session** | The summary's `source.time_label` is relative. Wall-clock times would put two clocks in one document that never line up |
  | Sessions concatenated without boundaries | **Session boundaries kept** | Long meetings split into parts looked like one blob |
  | No summary | **Summary included** | An obvious omission. The summary is this app's core deliverable |
  | No filename sanitization | Present | The original only had it on the audio download path, not for Markdown |

  ## Never include audio URLs

  Documents leave the meeting. If an unsigned object URL is embedded, anyone
  who receives the document can fetch the original recording. This module does
  not even **reference** `audio_url` or `storage_key`.

  ## Sessions without a transcript are still listed

  Skipping them means a reader with only the document never learns a segment is missing.
  """

  alias VR.Config
  alias VR.Meetings.{Meeting, RecordingSession, Speakers}
  alias VR.Summarize.Serializer

  @default_timezone "Asia/Seoul"

  @doc "The full meeting notes as Markdown."
  def to_markdown(%Meeting{} = meeting, sessions, opts \\ []) do
    sessions = Enum.sort_by(sessions, & &1.session_index)
    tz = opts[:timezone] || timezone()

    [
      header(meeting, sessions, tz),
      summary_section(meeting),
      transcript_section(sessions, tz)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n---\n\n")
  end

  @doc "The download filename. Path and control characters are removed."
  def filename(%Meeting{} = meeting) do
    base =
      (meeting.title || "Meeting")
      |> String.replace(~r/[\/\\:*?"<>|\x00-\x1f]/u, "_")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.trim(".")
      # Truncate by grapheme count, not bytes — multibyte characters (3 bytes
      # each in Korean) would be corrupted by a byte-level cut
      |> truncate_graphemes(60)

    base = if base == "", do: "Meeting", else: base

    "#{base}_#{date_stamp(meeting)}.md"
  end

  @doc """
  The `Content-Disposition` header.

  Non-ASCII titles break with `filename=` alone. **RFC 5987 `filename*` is sent alongside it.**
  """
  def content_disposition(%Meeting{} = meeting) do
    name = filename(meeting)
    ascii = name |> ascii_fallback() |> String.replace("\"", "")

    ~s(attachment; filename="#{ascii}"; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)})
    # Header injection defense. The filename already filters control characters, but block once more.
    |> String.replace(~r/[\r\n]/, "")
  end

  @doc "Is there anything to export?"
  def exportable?(%Meeting{} = meeting, sessions) do
    has_summary?(meeting) or Enum.any?(sessions, &(segments(&1) != []))
  end

  # ── Header ───────────────────────────────────────────────

  defp header(meeting, sessions, tz) do
    transcribed = Enum.count(sessions, &(segments(&1) != []))
    speakers = Speakers.names_in_order(sessions)

    lines =
      [
        "# #{escape_inline(meeting.title || "Untitled Meeting")}",
        "",
        "- **Date**: #{local_date(meeting, tz)} (#{tz})",
        duration_line(meeting),
        speakers != [] &&
          "- **Participants**: #{speakers |> Enum.map(&escape_inline/1) |> Enum.join(", ")}",
        sessions != [] &&
          "- **Sessions**: #{length(sessions)} (transcribed #{transcribed} / pending #{length(sessions) - transcribed})",
        ""
      ]
      |> Enum.reject(&(&1 in [nil, false]))

    Enum.join(lines, "\n")
  end

  defp duration_line(%Meeting{total_duration_seconds: seconds})
       when is_integer(seconds) and seconds > 0 do
    "- **Duration**: #{human_duration(seconds)}"
  end

  defp duration_line(_meeting), do: nil

  # ── Summary ──────────────────────────────────────────────

  defp summary_section(%Meeting{summary_data: data}) when is_map(data) and map_size(data) > 0 do
    [
      "## Summary",
      "",
      escape_block(data["one_liner"] || ""),
      "",
      sourced_block("### Decisions", data["decisions"], & &1["text"]),
      sourced_block("### Action Items", data["action_items"], &action_text/1),
      plain_block("### Key Facts", data["facts"]),
      plain_block("### Open Questions", data["open_questions"]),
      plain_block("### Next Steps", data["next_steps"]),
      topics_line(data["key_topics"]),
      meta_comment(data),
      ""
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp summary_section(_meeting), do: nil

  defp sourced_block(_title, items, _text_fun) when items in [nil, []], do: nil

  defp sourced_block(title, items, text_fun) when is_list(items) do
    body =
      Enum.map_join(items, "\n", fn item ->
        line = "- #{escape_block(text_fun.(item))}"

        case item["source"] do
          %{} = source -> line <> "\n" <> source_quote(source)
          _ -> line
        end
      end)

    "#{title}\n\n#{body}\n"
  end

  defp sourced_block(_title, _items, _text_fun), do: nil

  defp source_quote(source) do
    speaker = escape_inline(source["speaker"] || "")
    label = source["time_label"] || ""
    quote = source["quote"] |> to_string() |> String.replace(~r/\s*\n\s*/, " ") |> escape_inline()

    "  > #{speaker} · `#{label}` — \"#{quote}\""
  end

  defp action_text(item) do
    who = String.trim(to_string(item["who"] || ""))
    due = String.trim(to_string(item["due"] || ""))
    suffix = [who, due] |> Enum.reject(&(&1 == "")) |> Enum.join(" · ")

    if suffix == "", do: item["what"], else: "#{item["what"]} (#{suffix})"
  end

  defp plain_block(_title, items) when items in [nil, []], do: nil

  defp plain_block(title, items) when is_list(items) do
    "#{title}\n\n" <> Enum.map_join(items, "\n", &"- #{escape_block(&1)}") <> "\n"
  end

  defp plain_block(_title, _items), do: nil

  defp topics_line(topics) when is_list(topics) and topics != [] do
    "**Key Topics**: #{topics |> Enum.map(&escape_inline/1) |> Enum.join(", ")}\n"
  end

  defp topics_line(_topics), do: nil

  defp meta_comment(data) do
    parts = [data["model"], data["generated_at"]] |> Enum.reject(&(&1 in [nil, ""]))
    if parts == [], do: nil, else: "<!-- Summary: #{Enum.join(parts, " · ")} -->\n"
  end

  # ── Transcript ───────────────────────────────────────────

  defp transcript_section([], _tz), do: nil

  defp transcript_section(sessions, tz) do
    "## Transcript\n\n" <> Enum.map_join(sessions, "\n", &session_block(&1, tz))
  end

  defp session_block(%RecordingSession{} = session, tz) do
    case segments(session) do
      [] ->
        "### #{session_heading(session, tz)} — no transcript\n\nThis session was not transcribed and is not included in the body.\n"

      segments ->
        speaker_map = session.speaker_map || %{}

        body =
          Enum.map_join(segments, "\n", fn segment ->
            name = Speakers.display_name(speaker_map, segment["speaker"])
            label = Serializer.time_label(segment["start_ms"])

            # Put the text on the next line. A single-line format breaks when an utterance contains `:`.
            "**#{escape_inline(name)}** `#{label}`\n\n#{escape_block(segment["text"])}\n"
          end)

        "### #{session_heading(session, tz)}\n\n#{body}"
    end
  end

  defp session_heading(%RecordingSession{} = session, tz) do
    base = "Session #{session.session_index}"
    part = part_label(session)
    time = session_time_range(session, tz)

    [base, part, time] |> Enum.reject(&is_nil/1) |> Enum.join(" — ")
  end

  defp part_label(%RecordingSession{metadata: metadata}) when is_map(metadata) do
    case metadata["part"] do
      %{"index" => i, "total" => total} -> "Part #{i}/#{total}"
      %{"label" => label} when is_binary(label) -> label
      _ -> nil
    end
  end

  defp part_label(_session), do: nil

  defp session_time_range(%RecordingSession{started_at_unix: start} = session, tz)
       when is_integer(start) do
    started = local_time(start, tz)

    case session.duration_seconds do
      seconds when is_integer(seconds) and seconds > 0 ->
        ended = local_time(start + seconds, tz)
        "#{started} ~ #{ended} (#{human_duration(seconds)})"

      _ ->
        started
    end
  end

  defp session_time_range(_session, _tz), do: nil

  # ── Internal ─────────────────────────────────────────────

  defp segments(%RecordingSession{transcript: %{"segments" => segments}}) when is_list(segments),
    do: segments

  defp segments(_session), do: []

  defp has_summary?(%Meeting{summary_data: data}), do: is_map(data) and map_size(data) > 0

  # Not taken from the client. sisyphus used the browser's `Intl` value, so
  # Seoul and New York produced different documents.
  defp timezone do
    case Config.fetch("app.timezone") do
      value when is_binary(value) and value != "" -> value
      _ -> @default_timezone
    end
  end

  defp local_date(%Meeting{} = meeting, tz) do
    (meeting.started_at || meeting.inserted_at)
    |> shift(tz)
    |> case do
      nil -> "-"
      dt -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end

  defp local_time(unix, tz) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> shift(tz)
    |> case do
      nil -> "-"
      dt -> Calendar.strftime(dt, "%H:%M")
    end
  end

  defp shift(nil, _tz), do: nil

  defp shift(datetime, tz) do
    case DateTime.shift_zone(datetime, tz) do
      {:ok, shifted} -> shifted
      # The timezone DB is missing or the name is wrong. Emit UTC anyway — better than no document.
      _ -> datetime
    end
  end

  defp date_stamp(%Meeting{} = meeting) do
    (meeting.started_at || meeting.inserted_at || DateTime.utc_now())
    |> Calendar.strftime("%Y%m%d")
  end

  defp human_duration(seconds) do
    minutes = div(seconds, 60)
    rest = rem(seconds, 60)

    cond do
      minutes == 0 -> "#{rest} sec"
      rest == 0 -> "#{minutes} min"
      true -> "#{minutes} min #{rest} sec"
    end
  end

  defp truncate_graphemes(value, max) do
    value |> String.graphemes() |> Enum.take(max) |> Enum.join()
  end

  defp ascii_fallback(value) do
    value
    |> String.replace(~r/[^\x20-\x7e]/u, "_")
    |> String.replace(~r/_+/, "_")
  end

  # So Markdown does not break inside bold or code
  defp escape_inline(value) do
    value
    |> to_string()
    |> String.replace(~r/([\\`*_\[\]|])/u, "\\\\\\1")
  end

  # Body text only blocks line-leading markers. Escaping every `*` mid-sentence hurts readability.
  defp escape_block(value) do
    value
    |> to_string()
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      String.replace(line, ~r/^(\s*)([#>\-|]|```)/, "\\1\\\\\\2")
    end)
  end
end
