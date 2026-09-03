defmodule VR.Meetings.Speakers do
  @moduledoc """
  Speaker name resolution. **Only the fallback rules** are shared.

  **Source: sisyphus** — the three-step speaker-name fallback in
  `assets/webapp/meeting-recorder.js` (`speaker_map` name → account name →
  `Speaker N`). `member_id` was renamed to `account_id`.

  ## Why we do not reuse `VR.Summarize.Serializer`'s functions

  That side **deletes** `|` `[` `]` from names. That is not a display rule but a
  contract so the LLM prompt can parse `[session_id|speaker|HH:MM:SS]` labels.
  In Markdown they must be **escaped**, not deleted. So only the fallback is
  shared, and each side keeps its own sanitization.

  ## `speaker_map` is per session

  `speaker_1` can be a different person in each session. Caching across
  sessions attaches the wrong names.
  """

  alias VR.Meetings.RecordingSession

  @doc "The display name for this speaker key in this session."
  def display_name(speaker_map, key) when is_map(speaker_map) do
    case Map.get(speaker_map, key) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _ -> fallback(key)
    end
  end

  def display_name(_speaker_map, key), do: fallback(key)

  @doc "Speaker names across sessions in order of appearance. Used for the meeting-notes header."
  def names_in_order(sessions) when is_list(sessions) do
    sessions
    |> Enum.sort_by(& &1.session_index)
    |> Enum.flat_map(&session_names/1)
    |> Enum.uniq()
  end

  defp session_names(%RecordingSession{} = session) do
    speaker_map = session.speaker_map || %{}

    session.transcript
    |> segments()
    |> Enum.map(&display_name(speaker_map, &1["speaker"]))
  end

  defp segments(%{"segments" => segments}) when is_list(segments), do: segments
  defp segments(_), do: []

  defp fallback(key) when is_binary(key) do
    case Regex.run(~r/^speaker[_-]?(\d+)$/i, key) do
      [_, n] -> "Speaker #{n}"
      _ -> key
    end
  end

  defp fallback(_), do: "Speaker"
end
