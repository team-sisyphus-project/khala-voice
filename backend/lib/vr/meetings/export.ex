defmodule VR.Meetings.Export do
  @moduledoc """
  회의록 마크다운 내보내기.

  **출처: sisyphus** `assets/webapp/meeting-recorder.js` 의 `exportTranscriptMarkdown()`.
  형식을 참고하고 다음을 바꿨다.

  | sisyphus | 이 앱 | 왜 |
  |---|---|---|
  | 클라이언트가 Blob 으로 만듦 | **서버 렌더링** | 원본은 데스크톱이 `.md`, 모바일이 `.txt` 로 갈렸다. 한 벌만 둔다 |
  | 절대 벽시계 시각 | **세션 내 상대 `HH:MM:SS`** | 요약의 `source.time_label` 이 상대 시각이다. 벽시계로 쓰면 같은 문서 안에서 두 시계가 어긋나 대조가 안 된다 |
  | 세션을 구분 없이 이어 붙임 | **세션 경계를 남긴다** | 파트가 나뉜 긴 회의가 한 덩어리로 보였다 |
  | 요약 없음 | **요약 포함** | 명백한 누락. 요약이 이 앱의 핵심 산출물이다 |
  | 파일명 새니타이즈 없음 | 있음 | 원본은 오디오 다운로드 경로에만 있고 마크다운에는 빠져 있었다 |

  ## 오디오 주소를 절대 넣지 않는다

  문서는 회의 밖으로 나간다. 서명 없는 오브젝트 주소가 실리면 그 문서를 받은
  누구나 원본을 받을 수 있다. 이 모듈은 `audio_url` · `storage_key` 를 **참조조차 하지 않는다.**

  ## 전사 없는 세션도 남긴다

  건너뛰면 문서만 받은 사람이 빠진 구간이 있다는 사실을 모른다.
  """

  alias VR.Config
  alias VR.Meetings.{Meeting, RecordingSession, Speakers}
  alias VR.Summarize.Serializer

  @default_timezone "Asia/Seoul"

  @doc "회의록 전체를 마크다운으로."
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

  @doc "다운로드 파일명. 경로·제어 문자를 지운다."
  def filename(%Meeting{} = meeting) do
    base =
      (meeting.title || "회의")
      |> String.replace(~r/[\/\\:*?"<>|\x00-\x1f]/u, "_")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.trim(".")
      # 바이트가 아니라 글자 수로 자른다 — 한글이 3바이트라 바이트로 자르면 깨진다
      |> truncate_graphemes(60)

    base = if base == "", do: "회의", else: base

    "#{base}_#{date_stamp(meeting)}.md"
  end

  @doc """
  `Content-Disposition` 헤더.

  한글 제목은 `filename=` 만으로는 깨진다. **RFC 5987 `filename*` 을 함께 보낸다.**
  """
  def content_disposition(%Meeting{} = meeting) do
    name = filename(meeting)
    ascii = name |> ascii_fallback() |> String.replace("\"", "")

    ~s(attachment; filename="#{ascii}"; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)})
    # 헤더 인젝션 방어. 파일명은 이미 제어 문자를 걸렀지만 한 번 더 막는다.
    |> String.replace(~r/[\r\n]/, "")
  end

  @doc "내보낼 것이 있는가."
  def exportable?(%Meeting{} = meeting, sessions) do
    has_summary?(meeting) or Enum.any?(sessions, &(segments(&1) != []))
  end

  # ── 머리말 ───────────────────────────────────────────────

  defp header(meeting, sessions, tz) do
    transcribed = Enum.count(sessions, &(segments(&1) != []))
    speakers = Speakers.names_in_order(sessions)

    lines =
      [
        "# #{escape_inline(meeting.title || "제목 없는 회의")}",
        "",
        "- **날짜**: #{local_date(meeting, tz)} (#{tz})",
        duration_line(meeting),
        speakers != [] &&
          "- **참여자**: #{speakers |> Enum.map(&escape_inline/1) |> Enum.join(", ")}",
        sessions != [] &&
          "- **세션**: #{length(sessions)}개 (전사 완료 #{transcribed} / 미완 #{length(sessions) - transcribed})",
        ""
      ]
      |> Enum.reject(&(&1 in [nil, false]))

    Enum.join(lines, "\n")
  end

  defp duration_line(%Meeting{total_duration_seconds: seconds})
       when is_integer(seconds) and seconds > 0 do
    "- **길이**: #{human_duration(seconds)}"
  end

  defp duration_line(_meeting), do: nil

  # ── 요약 ─────────────────────────────────────────────────

  defp summary_section(%Meeting{summary_data: data}) when is_map(data) and map_size(data) > 0 do
    [
      "## 요약",
      "",
      escape_block(data["one_liner"] || ""),
      "",
      sourced_block("### 결정사항", data["decisions"], & &1["text"]),
      sourced_block("### 할 일", data["action_items"], &action_text/1),
      plain_block("### 주요 사실", data["facts"]),
      plain_block("### 열린 질문", data["open_questions"]),
      plain_block("### 다음 단계", data["next_steps"]),
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
    "**핵심 주제**: #{topics |> Enum.map(&escape_inline/1) |> Enum.join(", ")}\n"
  end

  defp topics_line(_topics), do: nil

  defp meta_comment(data) do
    parts = [data["model"], data["generated_at"]] |> Enum.reject(&(&1 in [nil, ""]))
    if parts == [], do: nil, else: "<!-- 요약: #{Enum.join(parts, " · ")} -->\n"
  end

  # ── 전사 ─────────────────────────────────────────────────

  defp transcript_section([], _tz), do: nil

  defp transcript_section(sessions, tz) do
    "## 전사\n\n" <> Enum.map_join(sessions, "\n", &session_block(&1, tz))
  end

  defp session_block(%RecordingSession{} = session, tz) do
    case segments(session) do
      [] ->
        "### #{session_heading(session, tz)} — 전사 없음\n\n이 세션은 전사되지 않아 본문에 포함되지 않았습니다.\n"

      segments ->
        speaker_map = session.speaker_map || %{}

        body =
          Enum.map_join(segments, "\n", fn segment ->
            name = Speakers.display_name(speaker_map, segment["speaker"])
            label = Serializer.time_label(segment["start_ms"])

            # 본문을 다음 줄로 내린다. 한 줄 형식은 발화에 `:` 가 있으면 깨진다.
            "**#{escape_inline(name)}** `#{label}`\n\n#{escape_block(segment["text"])}\n"
          end)

        "### #{session_heading(session, tz)}\n\n#{body}"
    end
  end

  defp session_heading(%RecordingSession{} = session, tz) do
    base = "세션 #{session.session_index}"
    part = part_label(session)
    time = session_time_range(session, tz)

    [base, part, time] |> Enum.reject(&is_nil/1) |> Enum.join(" — ")
  end

  defp part_label(%RecordingSession{metadata: metadata}) when is_map(metadata) do
    case metadata["part"] do
      %{"index" => i, "total" => total} -> "파트 #{i}/#{total}"
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

  # ── 내부 ─────────────────────────────────────────────────

  defp segments(%RecordingSession{transcript: %{"segments" => segments}}) when is_list(segments),
    do: segments

  defp segments(_session), do: []

  defp has_summary?(%Meeting{summary_data: data}), do: is_map(data) and map_size(data) > 0

  # 클라이언트에서 받지 않는다. sisyphus 는 브라우저의 `Intl` 값을 써서
  # 서울과 뉴욕에서 다른 문서가 나왔다.
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
      # 타임존 DB 가 없거나 이름이 틀렸다. UTC 로라도 낸다 — 문서를 못 만드는 것보다 낫다.
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
      minutes == 0 -> "#{rest}초"
      rest == 0 -> "#{minutes}분"
      true -> "#{minutes}분 #{rest}초"
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

  # 볼드·코드 안에서 마크다운이 깨지지 않게
  defp escape_inline(value) do
    value
    |> to_string()
    |> String.replace(~r/([\\`*_\[\]|])/u, "\\\\\\1")
  end

  # 본문은 줄머리 기호만 막는다. 문장 안의 `*` 까지 이스케이프하면 읽기 나빠진다.
  defp escape_block(value) do
    value
    |> to_string()
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      String.replace(line, ~r/^(\s*)([#>\-|]|```)/, "\\1\\\\\\2")
    end)
  end
end
