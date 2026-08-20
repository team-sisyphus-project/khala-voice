defmodule VRWeb.API.MeetingController do
  @moduledoc "회의 REST API."

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
      # 필터 화면이 "N개" 를 보여주려면 필요하다. 페이지가 아니라 전체 개수다.
      total: Meetings.count_meetings(account, opts)
    })
  end

  # 배열로도 쉼표 구분 문자열로도 받는다. URL 쿼리로 넘어오면 후자다.
  defp parse_ids(nil), do: nil
  defp parse_ids(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)

  defp parse_ids(ids) when is_binary(ids) do
    ids |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_ids(_), do: nil

  # 화이트리스트. 모르는 값이 오면 기본(AND)으로 좁힌다 —
  # 넓히는 쪽으로 기울면 필터가 조용히 무력해진다.
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
      # **바뀐 회의로 권한을 다시 계산한다.** 요청 전의 level 을 그대로 쓰면
      # Reviewer 를 넘긴 직후에도 응답이 `role: "reviewer"` 라고 답한다.
      # 프런트는 이 값을 보고 "권한을 잃었으니 화면을 뜨자"를 판단하므로,
      # 거짓말을 하면 사용자가 그 화면에 남아 있다가 다음 요청에서 404 를 맞는다.
      json(conn, JSONView.meeting(updated, Meetings.level(updated, account)))
    end
  end

  def update_status(conn, %{"id" => id, "status" => status}) do
    account = conn.assigns.current_account
    # 아카이브는 Reviewer만, 나머지 상태 변경은 Contributor 이상
    required = if status == "archived", do: :lv0, else: :lv1

    with {:ok, meeting, level} <- Meetings.authorize(id, account, required),
         true <- status in VR.Meetings.Meeting.statuses() || {:error, :invalid_status},
         {:ok, updated} <- Meetings.set_status(meeting, status) do
      json(conn, JSONView.meeting(updated, level))
    end
  end

  @doc """
  마크다운으로 내보낸다.

  **오디오 주소는 들어가지 않는다** — 문서는 회의 밖으로 나가기 때문이다.
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
  이 회의에 붙일 수 있는 분류.

  **회의 owner 의 것**을 준다. 내 것이 아니다 — Contributor 가 자기 라벨을 붙이면
  owner 의 아카이브 검색에 그 회의가 걸리지 않기 때문이다.
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
  요약을 만든다. 이미 있으면 다시 만든다 (모드 `retry`).

  큐잉만 하고 바로 응답한다 — LLM 호출은 수 분이 걸릴 수 있어
  HTTP 요청을 붙잡고 있을 수 없다. 완료는 폴링으로 확인한다.
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
