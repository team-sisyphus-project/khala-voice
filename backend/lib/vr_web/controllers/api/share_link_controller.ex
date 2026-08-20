defmodule VRWeb.API.ShareLinkController do
  @moduledoc """
  공유 링크 관리. **Reviewer 만** 쓸 수 있다.

  sisyphus 는 (a) lv0 또는 lv1 에게 열어 뒀고 (b) 프로젝트 멤버면 누구든 평문 토큰과
  PIN 을 읽고 남의 링크를 죽일 수 있었다(`shared_link_controller.ex` `authorized_for_link?`).
  이 앱은 **그 회의의 Reviewer** 한 사람만이다.

  ## 평문은 한 번만 나간다

  발급(`create`)과 재발급(`rotate`), PIN 켜기(`set_pincode`) 응답에만 평문이 실린다.
  이후 `index` 에는 `token_prefix` 와 `has_pincode` 만 있다.
  DB 에도 해시만 있으므로 잃어버리면 재발급뿐이다.
  """

  use VRWeb, :controller

  alias VR.{Meetings, Sharing}
  alias VR.Sharing.SharedLink
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  def index(conn, %{"meeting_id" => meeting_id}) do
    account = conn.assigns.current_account

    with {:ok, meeting, _level} <- Meetings.authorize(meeting_id, account, :lv0) do
      json(conn, %{share_links: Enum.map(Sharing.list_links(meeting.id), &JSONView.shared_link/1)})
    end
  end

  def create(conn, %{"meeting_id" => meeting_id} = params) do
    account = conn.assigns.current_account

    attrs =
      Map.take(
        params,
        ~w(granted_role max_uses expires_at require_name require_email with_pincode)
      )

    with {:ok, meeting, _level} <- Meetings.authorize(meeting_id, account, :lv0),
         {:ok, link, token, pincode} <- Sharing.issue_link(meeting, account, attrs) do
      conn
      |> put_status(:created)
      |> json(
        JSONView.shared_link(link)
        # 이 응답에만 실린다
        |> Map.put(:url, Sharing.link_url(token))
        |> Map.put(:pincode, pincode)
      )
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, link} <- authorize_link(conn, id),
         {:ok, updated} <-
           Sharing.update_link(
             link,
             Map.take(params, ~w(is_active max_uses expires_at require_name require_email))
           ) do
      json(conn, JSONView.shared_link(updated))
    end
  end

  @doc "주소를 잃어버렸을 때. 설정과 사용 횟수는 유지하고 토큰만 새로 만든다."
  def rotate(conn, %{"id" => id}) do
    with {:ok, link} <- authorize_link(conn, id),
         {:ok, updated, token} <- Sharing.rotate_token(link) do
      json(conn, Map.put(JSONView.shared_link(updated), :url, Sharing.link_url(token)))
    end
  end

  def set_pincode(conn, %{"id" => id} = params) do
    mode = if params["enabled"] in [true, "true"], do: :on, else: :off

    with {:ok, link} <- authorize_link(conn, id),
         {:ok, updated, pincode} <- Sharing.set_pincode(link, mode) do
      json(conn, Map.put(JSONView.shared_link(updated), :pincode, pincode))
    end
  end

  @doc "폐기. **이 링크로 들어와 있는 게스트도 끊긴다.**"
  def delete(conn, %{"id" => id}) do
    with {:ok, link} <- authorize_link(conn, id),
         {:ok, _} <- Sharing.revoke_link(link) do
      send_resp(conn, :no_content, "")
    end
  end

  # ── 내부 ─────────────────────────────────────────────────

  # 링크 id 로 회의를 찾아 그 회의의 Reviewer 인지 본다.
  # 링크가 없든 권한이 없든 **응답은 404 로 같다.**
  defp authorize_link(conn, id) do
    account = conn.assigns.current_account

    with %SharedLink{} = link <- Sharing.get_link(id),
         {:ok, _meeting, _level} <- Meetings.authorize(link.meeting_id, account, :lv0) do
      {:ok, link}
    else
      _ -> {:error, :not_found}
    end
  end
end
