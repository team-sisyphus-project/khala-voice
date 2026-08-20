defmodule VR.Summarize.Serializer do
  @moduledoc """
  전사를 LLM 입력 문자열로 직렬화한다.

  **출처: sisyphus** n8n `autosquad-meeting-summary.json` — 이 형식은
  프롬프트와 **합의된 규약**이다. 프롬프트가 이 라벨을 파싱해
  `source.session_id` · `source.speaker` · `source.time_label` 을 뽑는다.
  형식을 바꾸면 요약 항목 클릭 → 오디오 점프가 통째로 깨진다.

      [<session_id>|<speaker_name>|<HH:MM:SS>] 발화 내용

  ## 화자 이름에서 구분자를 지운다

  `|` 나 `]` 가 이름에 섞이면 프롬프트가 라벨을 잘못 자른다.
  사용자가 화자 이름을 자유롭게 고칠 수 있으므로 여기서 막는다.
  """

  alias VR.Meetings.RecordingSession

  @doc """
  한 번의 LLM 호출에 넣을 전사 길이(글자).

  이 값을 넘으면 **자르지 않고 나눠서 요약한다** (`VR.Summarize` 의 map-reduce).
  잘라내면 뒷부분이 요약에서 조용히 사라지고, 사용자는 그 사실을 알 방법이 없다.

  **sisyphus 는 여기서 잘랐다** — `meetings.ex:710` 의 `String.slice(0, 60_000)`.
  2시간 회의는 라벨까지 8만 자 안팎이라 뒤 3분의 1이 요약에 들어가지 않았고,
  요약은 멀쩡해 보였다. (사람들이 기억하는 "20분 단위로 잘 나눠 처리"는 요약이
  아니라 **전사** 쪽이다 — Google STT BatchRecognize 의 20분 제한 때문에
  오디오를 쪼갠 것이고, 그건 `AudioSplitWorker` 로 그대로 이식돼 있다.)
  """
  @chunk_chars 60_000

  def chunk_chars, do: @chunk_chars

  @doc """
  세션 목록을 하나의 전사 텍스트로 만든다.

  전사가 없는 세션은 건너뛴다. 어떤 세션이 들어가고 빠졌는지
  `summary_data` 에 남겨야 하므로 함께 돌려준다.
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
  발화 줄들을 한 번에 보낼 수 있는 덩어리로 나눈다.

  **줄 경계에서만 나눈다.** 줄 한가운데를 자르면 `[session|speaker|time]` 라벨이
  깨진 발화가 남고, 프롬프트가 그걸 근거로 삼아 출처가 틀린 요약이 나온다 —
  요약을 눌렀을 때 엉뚱한 지점이 재생된다.

  한 줄이 혼자서 상한을 넘으면(비정상적으로 긴 발화) 그 줄만 따로 담는다.
  자르는 것보다 모델이 알아서 줄이게 두는 편이 낫다.
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

  @doc "한 세션의 발화 줄들."
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
  `HH:MM:SS`. **항상 시간 자리까지 쓴다** — 프롬프트가 세 토막을 기대한다.
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

  @doc "`HH:MM:SS` → 밀리초. 요약의 `time_label` 로 오디오 위치를 찾을 때 쓴다."
  def parse_time_label(label) when is_binary(label) do
    case String.split(String.trim(label), ":") do
      [h, m, s] -> to_ms(h, m, s)
      [m, s] -> to_ms("0", m, s)
      _ -> nil
    end
  end

  def parse_time_label(_), do: nil

  # ── 내부 ─────────────────────────────────────────────────

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

  # 라벨 구분자가 이름에 섞이면 프롬프트가 라벨을 잘못 자른다
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
      [_, n] -> "화자 #{n}"
      _ -> key
    end
  end

  defp fallback_name(_), do: "화자"
end
