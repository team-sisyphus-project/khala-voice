defmodule VR.Meetings.Redact do
  @moduledoc """
  Removes from meeting responses **whatever must not leave the building**.

  The guest share view and the MCP server **use the same functions.** Keeping
  two copies means only one gets fixed and information leaks — that has already
  happened once in this repo (`docs/10-porting-map.md`).

  ## What gets removed

  | Field | Why |
  |---|---|
  | `owner_id` · `reviewer_id` · `contributor_ids` | Account IDs are not meeting content |
  | `permissions` | A Reviewer-only value |
  | `last_summary_error` | The raw failure carries internal exceptions verbatim |
  | `total_credits_charged` · `credits_charged` | Billing belongs to the meeting owner |
  | `error_message` | Ditto |
  | `speaker_map[].account_id` | Keep the name, drop only the account id. The UI uses names only |
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
  Trim a meeting response.

  `audio_href` is decided by the `:audio` option.

    * `{:rewrite, fun}` — takes a session id and builds a new path (guest share)
    * `:drop` — remove it entirely (MCP — we never hand out audio)
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

  # Handing out the account-only path unchanged means a guest just gets a 401 when clicking it
  defp audio(%{audio_href: _} = session, {:rewrite, fun}) when is_function(fun, 1),
    do: Map.put(session, :audio_href, fun.(session.id))

  defp audio(session, :drop), do: Map.drop(session, [:audio_href])
  defp audio(session, _), do: session

  @doc "Keep the name and remove only the account id."
  def speaker_map(map) when is_map(map) do
    Map.new(map, fn
      {key, %{} = entry} -> {key, Map.drop(entry, ["account_id", :account_id])}
      {key, value} -> {key, value}
    end)
  end

  def speaker_map(other), do: other
end
