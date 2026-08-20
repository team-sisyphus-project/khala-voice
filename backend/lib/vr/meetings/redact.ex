defmodule VR.Meetings.Redact do
  @moduledoc """
  회의 응답에서 **밖으로 나가면 안 되는 것**을 지운다.

  게스트 공유 뷰와 MCP 서버가 **같은 함수를 쓴다.** 두 벌로 두면 한쪽만 고쳐져
  정보가 샌다 — 실제로 그런 일이 이 리포에서 이미 한 번 있었다
  (`docs/10-porting-map.md`).

  ## 무엇을 지우나

  | 필드 | 왜 |
  |---|---|
  | `owner_id` · `reviewer_id` · `contributor_ids` | 계정 ID 는 회의 내용이 아니다 |
  | `permissions` | Reviewer 만 보는 값이다 |
  | `last_summary_error` | 실패 원문에 내부 예외가 그대로 들어 있다 |
  | `total_credits_charged` · `credits_charged` | 과금은 회의 소유자의 것이다 |
  | `error_message` | 〃 |
  | `speaker_map[].account_id` | 이름은 남기고 계정 id 만. 화면은 이름만 쓴다 |
  """

  @meeting_fields [
    :owner_id,
    :reviewer_id,
    :contributor_ids,
    :permissions,
    :last_summary_error,
    :total_credits_charged
  ]

  @session_fields [:credits_charged, :error_message]

  @doc """
  회의 응답을 다듬는다.

  `audio_href` 는 `:audio` 옵션이 정한다.

    * `{:rewrite, fun}` — 세션 id 를 받아 새 경로를 만든다 (게스트 공유)
    * `:drop` — 아예 뺀다 (MCP — 오디오를 주지 않는다)
  """
  def meeting(payload, opts \\ []) do
    payload
    |> Map.drop(@meeting_fields)
    |> Map.update(:recording_sessions, nil, &sessions(&1, opts))
  end

  defp sessions(nil, _opts), do: nil

  defp sessions(list, opts) when is_list(list) do
    Enum.map(list, fn session ->
      session
      |> Map.drop(@session_fields)
      |> Map.update(:speaker_map, %{}, &speaker_map/1)
      |> audio(opts[:audio])
    end)
  end

  defp sessions(other, _opts), do: other

  # 계정 전용 경로를 그대로 주면 게스트가 눌러도 401 만 난다
  defp audio(%{audio_href: _} = session, {:rewrite, fun}) when is_function(fun, 1),
    do: Map.put(session, :audio_href, fun.(session.id))

  defp audio(session, :drop), do: Map.drop(session, [:audio_href])
  defp audio(session, _), do: session

  @doc "이름은 남기고 계정 id 만 지운다."
  def speaker_map(map) when is_map(map) do
    Map.new(map, fn
      {key, %{} = entry} -> {key, Map.drop(entry, ["account_id", :account_id])}
      {key, value} -> {key, value}
    end)
  end

  def speaker_map(other), do: other
end
