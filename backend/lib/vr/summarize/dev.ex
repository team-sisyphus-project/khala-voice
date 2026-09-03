defmodule VR.Summarize.Dev do
  @moduledoc """
  Dev-mode mock summary.

  **Origin: sisyphus** — same idea as its `stt.dev_mode`:
  the whole summary UI must be verifiable without an LLM key.

  ## Sourced from the real transcript

  Returning fixed example sentences would make `source` verification fail
  every time, so **jump behavior could never be checked during development.**
  Instead we quote the actual labels from the serialized transcript.
  """

  @doc "Builds a mock summary from the serialized transcript."
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
        "open_questions" => ["(dev mode) Open questions will appear here once a real LLM is connected"],
        "next_steps" => ["(dev mode) Add a key under Admin -> LLM Providers to generate real summaries"],
        "key_topics" => ["dev mode", "mock summary"]
      }
      |> Jason.encode!()

    %{
      body: body,
      model: "dev-mock",
      provider: "dev",
      usage: %{input_tokens: 0, output_tokens: 0}
    }
  end

  defp one_liner(meeting, []), do: "#{meeting.title || "Meeting"} — no utterances found in the transcript to summarize. (dev mode)"

  defp one_liner(meeting, lines) do
    "#{meeting.title || "Meeting"} — summarized #{length(lines)} utterances. (dev-mode mock response)"
  end

  defp decisions(lines) do
    lines
    |> Enum.take(2)
    |> Enum.map(fn line ->
      %{"text" => "(dev mode) #{String.slice(quote_of(line), 0, 40)}", "source" => source_of(line)}
    end)
  end

  defp action_items(lines) do
    lines
    |> Enum.drop(2)
    |> Enum.take(2)
    |> Enum.map(fn line ->
      %{
        "who" => speaker_of(line),
        "what" => "(dev mode) #{String.slice(quote_of(line), 0, 40)}",
        "due" => "",
        "source" => source_of(line)
      }
    end)
  end

  # Parses `[session_id|speaker|HH:MM:SS] utterance` back apart
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
