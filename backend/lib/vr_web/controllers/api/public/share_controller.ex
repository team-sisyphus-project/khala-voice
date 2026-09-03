defmodule VRWeb.API.Public.ShareController do
  @moduledoc """
  Guest entry via share link. **The only API reachable without authentication.**

  ## No meeting id in the URL

  The meeting a guest sees is **determined by the guest session.** Putting a
  meeting id in the path would let it be swapped to point at another meeting,
  forcing every action to repeat the cross-check — and missing just one would
  open a hole. Removing it from the path eliminates that attack surface entirely.

  ## Every failure wears the same face

  | Situation | Response |
  |---|---|
  | Unknown token / malformed | 404 |
  | Expired / uses exhausted / inactive / revoked | 410 |
  | `guest_link_enabled` off (not signed in) | **404** — even the fact that the link was once valid is hidden |
  | Wrong PIN | 401 |
  | Too many PIN attempts | 429 |

  **The "why" is never included in the response.** Distinguishing expired from
  exhausted would leak that the token was once valid (410 does not distinguish
  the two).
  """

  use VRWeb, :controller

  alias VR.Meetings.Redact
  alias VR.{Meetings, Sharing}
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  @doc """
  Tells the guest what is required before entering. **No meeting content is returned.**
  """
  def show(conn, %{"token" => token}) do
    with {:ok, link} <- Sharing.fetch_by_token(token),
         :ok <- Sharing.check_usable(link) do
      json(conn, %{
        granted_role: link.granted_role,
        require_name: link.require_name,
        require_email: link.require_email,
        require_pincode: not is_nil(link.pin_hash),
        # Not even the meeting title is returned here — the PIN has not been passed yet
        already_signed_in: not is_nil(conn.assigns[:current_account])
      })
    end
  end

  @doc "Enter. Returns a guest token on success."
  def enter(conn, %{"token" => token} = params) do
    opts = [
      account: conn.assigns[:current_account],
      ip_address: client_ip(conn),
      user_agent: user_agent(conn)
    ]

    with {:ok, result} <- Sharing.enter(token, params, opts) do
      case result do
        # Signed-in accounts do not get a guest session. Account permissions take precedence.
        %{mode: :account, meeting: meeting} ->
          json(conn, %{mode: "account", redirect: "/go/meetings/#{meeting.id}", guest_token: nil})

        %{mode: :guest} = guest ->
          json(conn, %{
            mode: "guest",
            guest_token: guest.guest_token,
            granted_role: guest.granted_role,
            expires_at: guest.expires_at
          })
      end
    end
  end

  @doc "The meeting a guest sees. The meeting is **determined by the session.**"
  def meeting(conn, _params) do
    guest = conn.assigns.current_guest

    with {:ok, meeting, level} <- Sharing.guest_authorize(guest, :lv2) do
      sessions = Meetings.list_sessions(meeting.id)

      payload =
        meeting
        |> JSONView.meeting(level,
          sessions: sessions,
          taxonomy: VR.Taxonomy.resolve_for([meeting])
        )
        # Guests and MCP use **the same function** (`VR.Meetings.Redact`).
        # Audio is rewritten to the guest-only path — handing out the account
        # path would just produce a 401.
        |> Redact.meeting(audio: {:rewrite, &"/api/public/guest/sessions/#{&1}/audio"})

      json(conn, payload)
    end
  end

  @doc """
  Audio for a guest. **Verifies that the session belongs to that meeting.**

  Contributor guests edit the transcript, so they need to listen while editing.
  Viewer guests are stopped with a 404 at `guest_authorize(:lv1)` —
  the same rule as account Viewers.
  """
  def audio(conn, %{"id" => id}) do
    guest = conn.assigns.current_guest

    with {:ok, meeting, _level} <- Sharing.guest_authorize(guest, :lv1),
         %{} = session <- Meetings.get_session(id),
         # If it does not belong to the guest session's meeting, treat it as nonexistent
         true <- session.meeting_id == meeting.id,
         {:ok, url} <- presign_audio(session) do
      redirect(conn, external: url)
    else
      _ -> {:error, :not_found}
    end
  end

  defp presign_audio(%{storage_key: key, duration_seconds: seconds})
       when is_binary(key) and key != "" do
    VR.Storage.presign_download(key, expires_in: playback_ttl(seconds))
  end

  defp presign_audio(_session), do: {:error, :not_found}

  # Same rule as the account path (`RecordingSessionController`) — the signature must not die mid-playback
  defp playback_ttl(seconds) when is_integer(seconds) and seconds > 0,
    do: seconds |> Kernel.*(3) |> max(900) |> min(21_600)

  defp playback_ttl(_seconds), do: 900

  @doc "A guest leaves on their own."
  def leave(conn, _params) do
    Sharing.revoke_guest(conn.assigns.current_guest)
    send_resp(conn, :no_content, "")
  end

  # ── Internal ────────────────────────────────────────────

  # Guests never receive internal identifiers or operational information.
  #
  # `speaker_map` is easy to miss — each speaker carries an `account_id`, so
  # handing over just the transcript would leak every participant's account id.

  # `X-Forwarded-For` is trusted **only when enabled in configuration.**
  #
  # Trusting it blindly would let a single header line spoof the IP, defeating
  # the IP-based PIN brute-force limit. Only the deployer knows whether the app
  # sits behind a proxy.
  defp client_ip(conn) do
    if trust_proxy?() do
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
        _ -> peer_ip(conn)
      end
    else
      peer_ip(conn)
    end
  end

  defp peer_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  rescue
    _ -> nil
  end

  defp trust_proxy?, do: VR.Config.fetch("app.trust_proxy_headers") in [true, "true"]

  defp user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [value | _] -> value
      _ -> nil
    end
  end
end
