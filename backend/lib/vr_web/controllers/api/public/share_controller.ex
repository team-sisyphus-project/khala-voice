defmodule VRWeb.API.Public.ShareController do
  @moduledoc """
  공유 링크 게스트 진입. **인증 없이 닿는 유일한 API 다.**

  ## URL 에 회의 id 가 없다

  게스트가 볼 회의는 **게스트 세션이 정한다.** 경로에 회의 id 를 넣으면 그것을 바꿔
  다른 회의를 가리킬 수 있고, 그러면 액션마다 대조를 반복해야 하며 하나만 빠뜨려도
  뚫린다. 경로에서 아예 없애면 그 공격 표면이 사라진다.

  ## 실패는 전부 같은 얼굴을 한다

  | 상황 | 응답 |
  |---|---|
  | 토큰 없음 · 형식 오류 | 404 |
  | 만료 · 소진 · 비활성 · 폐기 | 410 |
  | `guest_link_enabled` 꺼짐 (비로그인) | **404** — 링크가 유효했다는 사실도 숨긴다 |
  | PIN 틀림 | 401 |
  | PIN 시도 초과 | 429 |

  **"왜" 를 응답에 싣지 않는다.** 만료인지 소진인지 알려주면 토큰이 한때 유효했다는
  정보가 새어 나간다 (410 은 둘을 구분하지 않는다).
  """

  use VRWeb, :controller

  alias VR.{Meetings, Sharing}
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  @doc """
  들어가기 전에 무엇이 필요한지 알려준다. **회의 내용은 아무것도 주지 않는다.**
  """
  def show(conn, %{"token" => token}) do
    with {:ok, link} <- Sharing.fetch_by_token(token),
         :ok <- Sharing.check_usable(link) do
      json(conn, %{
        granted_role: link.granted_role,
        require_name: link.require_name,
        require_email: link.require_email,
        require_pincode: not is_nil(link.pin_hash),
        # 회의 제목조차 여기서 주지 않는다 — PIN 을 통과하기 전이다
        already_signed_in: not is_nil(conn.assigns[:current_account])
      })
    end
  end

  @doc "입장. 성공하면 게스트 토큰을 준다."
  def enter(conn, %{"token" => token} = params) do
    opts = [
      account: conn.assigns[:current_account],
      ip_address: client_ip(conn),
      user_agent: user_agent(conn)
    ]

    with {:ok, result} <- Sharing.enter(token, params, opts) do
      case result do
        # 로그인한 계정은 게스트 세션을 만들지 않는다. 계정 권한이 우선이다.
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

  @doc "게스트가 보는 회의. 회의는 **세션이 정한다.**"
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
        |> strip_internal()

      json(conn, payload)
    end
  end

  @doc """
  게스트의 오디오. **세션이 그 회의의 것인지 확인한다.**

  Contributor 게스트는 전사를 고치는 사람이라 들으면서 고쳐야 한다.
  Viewer 게스트는 `guest_authorize(:lv1)` 에서 404 로 걸린다 —
  계정 Viewer 와 같은 규칙이다.
  """
  def audio(conn, %{"id" => id}) do
    guest = conn.assigns.current_guest

    with {:ok, meeting, _level} <- Sharing.guest_authorize(guest, :lv1),
         %{} = session <- Meetings.get_session(id),
         # 게스트 세션이 가진 회의의 것이 아니면 없는 것과 같다
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

  # 계정 경로(`RecordingSessionController`)와 같은 규칙 — 재생 도중 서명이 죽으면 안 된다
  defp playback_ttl(seconds) when is_integer(seconds) and seconds > 0,
    do: seconds |> Kernel.*(3) |> max(900) |> min(21_600)

  defp playback_ttl(_seconds), do: 900

  @doc "게스트가 스스로 나간다."
  def leave(conn, _params) do
    Sharing.revoke_guest(conn.assigns.current_guest)
    send_resp(conn, :no_content, "")
  end

  # ── 내부 ─────────────────────────────────────────────────

  # 게스트에게 내부 식별자와 운영 정보를 주지 않는다.
  #
  # `speaker_map` 을 빠뜨리기 쉽다 — 화자마다 `account_id` 가 붙어 있어서
  # 전사만 넘겨도 참여자 계정 id 가 통째로 새어 나간다.
  defp strip_internal(payload) do
    payload
    |> Map.drop([
      :owner_id,
      :reviewer_id,
      :contributor_ids,
      :permissions,
      # 실패 원문에 내부 예외가 그대로 들어 있다
      :last_summary_error,
      # 과금 정보는 회의 소유자의 것이다
      :total_credits_charged
    ])
    |> Map.update(:recording_sessions, nil, &strip_sessions/1)
  end

  defp strip_sessions(nil), do: nil

  defp strip_sessions(sessions) when is_list(sessions) do
    Enum.map(sessions, fn session ->
      session
      |> Map.drop([:credits_charged, :error_message])
      |> Map.update(:speaker_map, %{}, &strip_speaker_accounts/1)
      # 계정 전용 경로를 그대로 주면 게스트가 눌러도 401 만 난다
      |> rewrite_audio_href()
    end)
  end

  defp rewrite_audio_href(%{audio_href: _} = session) do
    Map.put(session, :audio_href, "/api/public/guest/sessions/#{session.id}/audio")
  end

  defp rewrite_audio_href(session), do: session

  # 이름은 남기고 계정 id 만 지운다. 화면은 이름만 쓴다.
  defp strip_speaker_accounts(speaker_map) when is_map(speaker_map) do
    Map.new(speaker_map, fn
      {key, %{} = entry} -> {key, Map.drop(entry, ["account_id", :account_id])}
      {key, value} -> {key, value}
    end)
  end

  defp strip_speaker_accounts(other), do: other

  # `X-Forwarded-For` 는 **설정으로 켰을 때만** 믿는다.
  #
  # 그냥 믿으면 헤더 한 줄로 IP 를 바꿀 수 있어 IP 기준 PIN 대입 제한이 무력해진다.
  # 앱이 프록시 뒤에 있는지는 배포자만 안다.
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
