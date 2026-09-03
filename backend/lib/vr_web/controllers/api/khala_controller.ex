defmodule VRWeb.API.KhalaController do
  @moduledoc """
  Khala integration API — status, inbox listing, and sending.

  The OAuth round trip must happen in the browser, so it lives in
  `VRWeb.KhalaController`. This module is the side the app calls.
  """

  use VRWeb, :controller

  alias VR.{Khala, Meetings}

  action_fallback VRWeb.API.FallbackController

  @doc "Connection status. Decides whether the UI shows the \"Connect\" button."
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

  @doc "My Khala inbox list. Used to pick a destination for sending."
  def inboxes(conn, _params) do
    account = conn.assigns.current_account

    case Khala.list_inboxes(account.id) do
      {:ok, inboxes} -> json(conn, %{inboxes: inboxes})
      {:error, reason} -> {:error, translate(reason)}
    end
  end

  @doc "Disconnects."
  def disconnect(conn, _params) do
    account = conn.assigns.current_account

    case Khala.disconnect(account.id) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, :not_connected} -> send_resp(conn, :no_content, "")
      {:error, reason} -> {:error, translate(reason)}
    end
  end

  @doc """
  Sends a meeting to Khala.

  **Only the Reviewer may send** (`:lv0`). This pushes meeting notes outside the
  app, so it is gated like export and share — the fact that a Contributor can
  edit the transcript does not grant them permission to send it to someone
  else's inbox.
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

  # Translate into something the user can act on. Internal details are not exposed as-is.
  defp translate(:not_connected), do: :khala_not_connected
  defp translate(:reconnect_required), do: :khala_reconnect_required
  defp translate(:missing_recipient), do: :bad_request
  defp translate(reason), do: reason
end
