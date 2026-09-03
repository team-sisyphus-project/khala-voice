defmodule VRWeb.API.MeetingController do
  @moduledoc "Meeting REST API."

  use VRWeb, :controller

  alias VR.{Meetings, Taxonomy}
  alias VR.Meetings.Export
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  def index(conn, params) do
    account = conn.assigns.current_account

    opts = [
      status: params["status"],
      topic_id: params["topic_id"],
      label_ids: parse_ids(params["label_ids"]),
      label_mode: parse_label_mode(params["label_mode"]),
      participant_id: params["participant_id"],
      order: parse_order(params["order"]),
      q: params["q"],
      from: parse_time(params["from"]),
      to: parse_time(params["to"]),
      limit: parse_int(params["limit"]),
      offset: parse_int(params["offset"])
    ]

    meetings = Meetings.list_meetings(account, opts)
    taxonomy = Taxonomy.resolve_for(meetings)

    json(conn, %{
      meetings:
        Enum.map(meetings, fn m ->
          JSONView.meeting(m, Meetings.level(m, account), taxonomy: taxonomy)
        end),
      # Needed so the filter UI can show "N results". This is the total count, not the page size.
      total: Meetings.count_meetings(account, opts)
    })
  end

  # Accepts both an array and a comma-separated string. URL query params arrive as the latter.
  defp parse_ids(nil), do: nil
  defp parse_ids(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)

  defp parse_ids(ids) when is_binary(ids) do
    ids |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_ids(_), do: nil

  # Whitelist. Unknown values fall back to the default (AND), which narrows —
  # leaning toward widening would silently defeat the filter.
  defp parse_label_mode("or"), do: "or"
  defp parse_label_mode(_), do: "and"

  defp parse_order("archived_desc"), do: "archived_desc"
  defp parse_order(_), do: nil

  def create(conn, params) do
    account = conn.assigns.current_account

    with {:ok, meeting} <-
           Meetings.create_meeting(
             account,
             Map.take(params, ~w(title description topic_id label_ids started_at))
           ) do
      conn
      |> put_status(:created)
      |> json(JSONView.meeting(meeting, :lv0, sessions: []))
    end
  end

  def show(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, meeting, level} <- Meetings.authorize(id, account, :lv2) do
      sessions = Meetings.list_sessions(meeting.id)

      json(
        conn,
        JSONView.meeting(meeting, level,
          sessions: sessions,
          taxonomy: Taxonomy.resolve_for([meeting])
        )
      )
    end
  end

  def update(conn, %{"id" => id} = params) do
    account = conn.assigns.current_account

    with {:ok, meeting, level} <- Meetings.authorize(id, account, :lv1),
         {:ok, updated} <-
           Meetings.update_meeting(
             meeting,
             Map.take(params, ~w(title description topic_id label_ids started_at))
           ) do
      json(conn, JSONView.meeting(updated, level))
    end
  end

  def update_permissions(conn, %{"id" => id} = params) do
    account = conn.assigns.current_account

    with {:ok, meeting, _level} <- Meetings.authorize(id, account, :lv0),
         {:ok, updated} <-
           Meetings.update_permissions(
             meeting,
             Map.take(params, ~w(reviewer_id contributor_ids permissions guest_link_enabled))
           ) do
      # **Recompute permissions against the updated meeting.** Reusing the
      # pre-request level would make the response say `role: "reviewer"` even
      # right after handing the Reviewer role away. The frontend uses this value
      # to decide "I lost access, leave this screen" — lie here and the user
      # stays on the screen only to hit a 404 on the next request.
      json(conn, JSONView.meeting(updated, Meetings.level(updated, account)))
    end
  end

  def update_status(conn, %{"id" => id, "status" => status}) do
    account = conn.assigns.current_account
    # Archiving is Reviewer-only; other status changes require Contributor or above
    required = if status == "archived", do: :lv0, else: :lv1

    with {:ok, meeting, level} <- Meetings.authorize(id, account, required),
         true <- status in VR.Meetings.Meeting.statuses() || {:error, :invalid_status},
         {:ok, updated} <- Meetings.set_status(meeting, status) do
      json(conn, JSONView.meeting(updated, level))
    end
  end

  @doc """
  Exports as Markdown.

  **Audio URLs are never included** — the document leaves the meeting.
  """
  def export_markdown(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, meeting, _level} <- Meetings.authorize(id, account, :lv2),
         sessions <- Meetings.list_sessions(meeting.id),
         true <- Export.exportable?(meeting, sessions) do
      conn
      |> put_resp_content_type("text/markdown")
      |> put_resp_header("content-disposition", Export.content_disposition(meeting))
      |> put_resp_header("cache-control", "private, no-store")
      |> send_resp(200, Export.to_markdown(meeting, sessions))
    else
      false -> {:error, :no_transcript}
      other -> other
    end
  end

  @doc """
  The taxonomy that can be attached to this meeting.

  Returns **the meeting owner's** taxonomy, not the caller's — if a Contributor
  attached their own labels, the meeting would not show up in the owner's
  archive search.
  """
  def taxonomy(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, meeting, _level} <- Meetings.authorize(id, account, :lv1) do
      json(conn, %{
        topics: Enum.map(Taxonomy.list_topics(meeting.owner_id), &JSONView.topic/1),
        labels: Enum.map(Taxonomy.list_labels(meeting.owner_id), &JSONView.label/1)
      })
    end
  end

  @doc """
  Generates a summary. If one already exists, it is regenerated (mode `retry`).

  Queue only and respond immediately — an LLM call can take minutes, and an
  HTTP request cannot be held open that long. Completion is checked via polling.
  """
  def summarize(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, meeting, _level} <- Meetings.authorize(id, account, :lv1),
         :ok <- ensure_summarizable(meeting) do
      {:ok, _job} = VR.Summarize.enqueue(meeting, "retry")

      conn
      |> put_status(:accepted)
      |> json(%{status: "queued", meeting_id: meeting.id})
    end
  end

  defp ensure_summarizable(meeting) do
    cond do
      not VR.Summarize.ready?() -> {:error, :summarize_unavailable}
      VR.Summarize.summarizable_sessions(meeting) == [] -> {:error, :no_transcript}
      true -> :ok
    end
  end

  def delete(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, meeting, _level} <- Meetings.authorize(id, account, :lv0),
         {:ok, _} <- Meetings.delete_meeting(meeting) do
      send_resp(conn, :no_content, "")
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 and n <= 200 -> n
      _ -> nil
    end
  end
end
