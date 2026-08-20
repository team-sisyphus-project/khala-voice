defmodule VRWeb.GuestAuth do
  @moduledoc """
  게스트 세션을 `conn` 에 붙인다.

  ## 왜 쿠키가 아니라 헤더인가

  `:api` 파이프라인에는 `protect_from_forgery` 가 없다. 게스트 자격을 쿠키에 담으면
  CSRF 표면이 생긴다. 쿠키는 도메인 전역이기도 해서 "회의 하나만"이라는 제약과 어긋난다.
  그래서 `X-Guest-Token` 헤더로 받고, 프런트는 `sessionStorage` 에 둔다.

  ## 이 플러그는 거절하지 않는다

  세션이 없으면 `nil` 로 두고 지나간다. 거절은 각 액션이 `guest_authorize/2` 로 한다 —
  "토큰이 없다"와 "권한이 없다"의 응답을 같게 만들기 위해서다.
  """

  import Plug.Conn

  alias VR.Sharing

  @header "x-guest-token"

  # `VRWeb.UserAuth` 와 같은 방식 — 파이프라인이 액션 이름을 준다.
  # `plug VRWeb.GuestAuth` 처럼 이름 없이 쓰면 기본 동작(붙이기만)이다.
  def init([]), do: :fetch_current_guest
  def init(nil), do: :fetch_current_guest
  def init(action) when is_atom(action), do: action

  def call(conn, action) when is_atom(action) and not is_nil(action),
    do: apply(__MODULE__, action, [conn, []])

  def call(conn, _opts), do: fetch_current_guest(conn, [])

  @doc "게스트 세션이 있으면 붙인다. 없어도 지나간다."
  def fetch_current_guest(conn, _opts) do
    case get_req_header(conn, @header) do
      [token | _] ->
        case Sharing.fetch_live_guest(token) do
          {:ok, session} -> assign(conn, :current_guest, session)
          :error -> assign(conn, :current_guest, nil)
        end

      _ ->
        assign(conn, :current_guest, nil)
    end
  end

  @doc "게스트 세션이 있어야 지나간다. 없으면 401."
  def require_guest(conn, _opts) do
    conn =
      if Map.has_key?(conn.assigns, :current_guest), do: conn, else: fetch_current_guest(conn, [])

    if conn.assigns[:current_guest] do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        401,
        Jason.encode!(%{
          status: "error",
          code: "guest_session_required",
          message: "공유 링크로 다시 들어와 주세요"
        })
      )
      |> halt()
    end
  end
end
