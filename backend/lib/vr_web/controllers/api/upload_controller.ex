defmodule VRWeb.API.UploadController do
  @moduledoc """
  Upload URL issuance.

  The browser uploads **directly** to S3, never through the app server —
  an hour-long recording is tens of megabytes, and passing it through would
  waste memory and bandwidth outright.
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
         # The key is **chosen by the server and recorded here** — so that we
         # never have to trust an address reported by the client after the upload.
         {:ok, _session} <- Meetings.set_storage_key(session, key),
         {:ok, result} <- Storage.presign_upload(key: key, content_type: content_type) do
      json(conn, result)
    end
  end

  # Re-issuing a presign for a finished session would allow a PUT to the same key, overwriting the original.
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
