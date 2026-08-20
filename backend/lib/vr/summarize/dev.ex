defmodule VR.Summarize.Dev do
  @moduledoc """
  개발 모드 목 요약.

  **출처: sisyphus** 의 `stt.dev_mode` 와 같은 발상 —
  LLM 키 없이도 요약 화면 전체를 확인할 수 있어야 한다.

  ## 진짜 전사에서 뽑는다

  고정된 예시 문장을 돌려주면 `source` 검증이 항상 실패해
  **점프가 되는지 아닌지를 개발 중에 확인할 수 없다.**
  그래서 직렬화된 전사의 실제 라벨을 그대로 인용한다.
  """

  @doc "직렬화된 전사에서 목 요약을 만든다."
  def result(meeting, text) do
    lines =
      text
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "["))

    body =
      %{
        "one_liner" => one_liner(meeting, lines),
        "decisions" => decisions(lines),
        "action_items" => action_items(lines),
        "facts" => Enum.map(Enum.take(lines, 2), &quote_of/1),
        "open_questions" => ["(개발 모드) 실제 LLM 이 연결되면 여기에 미결 사항이 들어간다"],
        "next_steps" => ["(개발 모드) 어드민 → LLM 제공자에서 키를 넣으면 실제 요약이 생성된다"],
        "key_topics" => ["개발 모드", "목 요약"]
      }
      |> Jason.encode!()

    %{
      body: body,
      model: "dev-mock",
      provider: "dev",
      usage: %{input_tokens: 0, output_tokens: 0}
    }
  end

  defp one_liner(meeting, []), do: "#{meeting.title || "회의"} — 전사에서 요약할 발화를 찾지 못했다. (개발 모드)"

  defp one_liner(meeting, lines) do
    "#{meeting.title || "회의"} — 발화 #{length(lines)}건을 요약했다. (개발 모드 목 응답)"
  end

  defp decisions(lines) do
    lines
    |> Enum.take(2)
    |> Enum.map(fn line ->
      %{"text" => "(개발 모드) #{String.slice(quote_of(line), 0, 40)}", "source" => source_of(line)}
    end)
  end

  defp action_items(lines) do
    lines
    |> Enum.drop(2)
    |> Enum.take(2)
    |> Enum.map(fn line ->
      %{
        "who" => speaker_of(line),
        "what" => "(개발 모드) #{String.slice(quote_of(line), 0, 40)}",
        "due" => "",
        "source" => source_of(line)
      }
    end)
  end

  # `[session_id|speaker|HH:MM:SS] 발화` 를 되짚는다
  defp source_of(line) do
    case parse(line) do
      {session_id, speaker, label, quote} ->
        %{
          "session_id" => session_id,
          "speaker" => speaker,
          "time_label" => label,
          "quote" => quote
        }

      nil ->
        nil
    end
  end

  defp speaker_of(line) do
    case parse(line) do
      {_, speaker, _, _} -> speaker
      nil -> ""
    end
  end

  defp quote_of(line) do
    case parse(line) do
      {_, _, _, quote} -> quote
      nil -> line
    end
  end

  defp parse(line) do
    case Regex.run(~r/^\[([^\|\]]+)\|([^\|\]]*)\|([^\|\]]+)\]\s*(.*)$/s, line) do
      [_, session_id, speaker, label, quote] -> {session_id, speaker, label, quote}
      _ -> nil
    end
  end
end
