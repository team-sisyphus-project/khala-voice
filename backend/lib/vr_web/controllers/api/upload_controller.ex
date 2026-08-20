defmodule VRWeb.API.UploadController do
  @moduledoc """
  업로드 URL 발급.

  브라우저가 S3에 **직접** 올린다. 앱 서버를 거치지 않는다 —
  1시간 녹음이 수십 MB인데 통과시키면 메모리와 대역폭이 그대로 낭비된다.
  """

  use VRWeb, :controller

  alias VR.{Meetings, Storage}

  action_fallback VRWeb.API.FallbackController

  def presign(conn, %{"session_id" => session_id} = params) do
    account = conn.assigns.current_account
    content_type = params["content_type"] || "audio/webm"

    with {:ok, session} <- load_session(session_id),
         {:ok, meeting, _level} <- Meetings.authorize(session.meeting_id, account, :lv1),
         :ok <- ensure_mutable(meeting),
         :ok <- ensure_presignable(session),
         :ok <- validate_mime(content_type),
         key <-
           Storage.recording_key(
             meeting.id,
             session.id,
             session.started_at_unix,
             Storage.extension_for(content_type)
           ),
         # 키는 **서버가 정하고 여기서 기록한다.** 업로드가 끝난 뒤
         # 클라이언트가 알려주는 주소를 믿지 않기 위한 것이다.
         {:ok, _session} <- Meetings.set_storage_key(session, key),
         {:ok, result} <- Storage.presign_upload(key: key, content_type: content_type) do
      json(conn, result)
    end
  end

  # 업로드가 끝난 세션에 presign 을 다시 내주면 같은 키에 PUT 해서 원본을 덮을 수 있다.
  defp ensure_presignable(%{status: "recording"}), do: :ok
  defp ensure_presignable(_session), do: {:error, :already_uploaded}

  defp ensure_mutable(%{status: "archived"}), do: {:error, :meeting_archived}
  defp ensure_mutable(_meeting), do: :ok

  defp load_session(id) do
    case Meetings.get_session(id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  defp validate_mime(mime) do
    if Storage.allowed_mime?(mime), do: :ok, else: {:error, :unsupported_media_type}
  end
end
