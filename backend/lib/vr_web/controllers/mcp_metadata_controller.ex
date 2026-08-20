defmodule VRWeb.MCPMetadataController do
  @moduledoc """
  MCP 자원 메타데이터 (RFC 9728).

  MCP 클라이언트는 401 을 받으면 `WWW-Authenticate` 가 가리키는 이 문서를 읽고
  어떻게 인증해야 하는지 알아낸다.

  **우리는 인가 서버가 아니다.** 칼라처럼 OAuth 흐름을 제공하지 않고, 사용자가
  설정 화면에서 만든 토큰을 그대로 쓴다. 그래서 `authorization_servers` 를
  비워 두고 `bearer_methods_supported` 만 알린다 — 그게 사실이다.
  """

  use VRWeb, :controller

  def show(conn, _params) do
    base = VRWeb.Endpoint.url() |> String.trim_trailing("/")

    json(conn, %{
      resource: base <> "/mcp",
      resource_name: "KHALA VOICE",
      resource_documentation: base <> "/go/settings",
      bearer_methods_supported: ["header"],
      scopes_supported: ["archive:read"]
    })
  end
end
