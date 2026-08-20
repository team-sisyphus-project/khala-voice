defmodule VRWeb.MCPAuth do
  @moduledoc """
  MCP 서버의 Bearer 토큰 인증.

  ## 401 에 무엇을 담나

  RFC 9728 대로 `WWW-Authenticate` 에 자원 메타데이터 주소를 담는다.
  MCP 클라이언트가 이걸 보고 어떻게 인증해야 하는지 알아낸다 — 칼라가
  우리에게 하는 것과 같은 방식이다.

  ## 왜 404 가 아니라 401 인가

  이 앱의 규칙은 "접근 불가는 404"지만(`docs/05-auth-sharing.md`), 그건
  **어떤 리소스가 있는지 숨기는** 이야기다. 여기서는 리소스가 아니라
  프로토콜 진입점이고, 클라이언트가 인증 방법을 알아야 하므로 401 이 맞다.
  회의 하나하나에 대한 판정은 그 뒤에 여전히 404 로 답한다.
  """

  import Plug.Conn

  alias VR.{Accounts, MCP}

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, account_id} <- MCP.authenticate(String.trim(token)),
         account when not is_nil(account) <- Accounts.get_account(account_id) do
      assign(conn, :mcp_account, account)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    metadata = VRWeb.Endpoint.url() |> String.trim_trailing("/")

    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Bearer resource_metadata="#{metadata}/.well-known/oauth-protected-resource/mcp")
    )
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: nil,
        error: %{
          code: -32_001,
          message: "인증이 필요합니다. 설정 → 연동에서 읽기 토큰을 만드세요."
        }
      })
    )
    |> halt()
  end
end
