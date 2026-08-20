defmodule VR.Meetings.Speakers do
  @moduledoc """
  화자 이름 해석. **폴백 규칙만** 공유한다.

  **출처: sisyphus** `assets/webapp/meeting-recorder.js` 의 화자명 3단 폴백
  (`speaker_map` 이름 → 계정 이름 → `화자 N`). `member_id` 를 `account_id` 로 바꿨다.

  ## `VR.Summarize.Serializer` 의 함수를 재사용하지 않는 이유

  그쪽은 이름에서 `|` `[` `]` 를 **지운다.** 그건 표시 규칙이 아니라 LLM 프롬프트가
  `[session_id|speaker|HH:MM:SS]` 라벨을 파싱하기 위한 계약이다. 마크다운에서는
  지우는 것이 아니라 **이스케이프**해야 한다. 그래서 폴백만 공유하고
  새니타이즈는 각자 갖는다.

  ## `speaker_map` 은 세션별이다

  세션마다 `speaker_1` 이 다른 사람일 수 있다. 세션을 가로질러 캐싱하면
  엉뚱한 이름이 붙는다.
  """

  alias VR.Meetings.RecordingSession

  @doc "이 세션에서 이 화자 키의 표시 이름."
  def display_name(speaker_map, key) when is_map(speaker_map) do
    case Map.get(speaker_map, key) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _ -> fallback(key)
    end
  end

  def display_name(_speaker_map, key), do: fallback(key)

  @doc "세션들에 등장한 화자 이름을 등장 순서대로. 회의록 머리말에 쓴다."
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
      [_, n] -> "화자 #{n}"
      _ -> key
    end
  end

  defp fallback(_), do: "화자"
end
