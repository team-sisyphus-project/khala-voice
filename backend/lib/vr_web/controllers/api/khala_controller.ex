defmodule VRWeb.API.KhalaController do
  @moduledoc """
  칼라 연동 API — 상태 · 인박스 목록 · 발송.

  OAuth 왕복은 브라우저가 해야 해서 `VRWeb.KhalaController` 에 있다.
  여기는 앱이 부르는 쪽이다.
  """

  use VRWeb, :controller

  alias VR.{Khala, Meetings}

  action_fallback VRWeb.API.FallbackController

  @doc "연결 상태. 화면이 '연결하기'를 띄울지 정한다."
  def show(conn, _params) do
    account = conn.assigns.current_account

    json(conn, %{
      enabled: Khala.OAuth.enabled?(),
      connected: Khala.connected?(account.id),
      inbox: inbox_of(Khala.connection(account.id))
    })
  end

  defp inbox_of(nil), do: nil
  defp inbox_of(%{inbox_code: nil}), do: nil
  defp inbox_of(%{inbox_code: code, inbox_name: name}), do: %{code: code, name: name}

  @doc "내 칼라 인박스 목록. 보낼 곳을 고르는 데 쓴다."
  def inboxes(conn, _params) do
    account = conn.assigns.current_account

    case Khala.list_inboxes(account.id) do
      {:ok, inboxes} -> json(conn, %{inboxes: inboxes})
      {:error, reason} -> {:error, translate(reason)}
    end
  end

  @doc "연결을 끊는다."
  def disconnect(conn, _params) do
    account = conn.assigns.current_account

    case Khala.disconnect(account.id) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, :not_connected} -> send_resp(conn, :no_content, "")
      {:error, reason} -> {:error, translate(reason)}
    end
  end

  @doc """
  회의를 칼라로 보낸다.

  **Reviewer 만 보낼 수 있다** (`:lv0`). 회의록을 밖으로 내보내는 일이라
  내보내기·공유와 같은 등급이다 — Contributor 가 전사를 고칠 수 있다고 해서
  남의 인박스로 보낼 권한까지 갖는 것은 아니다.
  """
  def send_meeting(conn, %{"meeting_id" => meeting_id} = params) do
    account = conn.assigns.current_account
    recipient = params["recipient_inbox_code"]
    attach? = params["attach_transcript"] != false

    with {:ok, meeting, _level} <- Meetings.authorize(meeting_id, account, :lv0),
         :ok <- ensure_recipient(recipient),
         :ok <-
           Khala.send_meeting(account.id, meeting, recipient,
             attach_transcript: attach?,
             app_url: app_url(conn)
           ) do
      json(conn, %{sent: true})
    else
      {:error, reason} -> {:error, translate(reason)}
    end
  end

  defp ensure_recipient(code) when is_binary(code) and code != "", do: :ok
  defp ensure_recipient(_), do: {:error, :missing_recipient}

  defp app_url(_conn), do: VRWeb.Endpoint.url() |> String.trim_trailing("/")

  # 사용자가 할 수 있는 일로 번역한다. 내부 사정을 그대로 내보내지 않는다.
  defp translate(:not_connected), do: :khala_not_connected
  defp translate(:reconnect_required), do: :khala_reconnect_required
  defp translate(:missing_recipient), do: :bad_request
  defp translate(reason), do: reason
end
