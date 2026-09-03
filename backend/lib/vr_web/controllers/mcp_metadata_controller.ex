defmodule VRWeb.MCPMetadataController do
  @moduledoc """
  MCP resource metadata (RFC 9728).

  When an MCP client receives a 401, it reads this document — pointed to by
  `WWW-Authenticate` — to learn how to authenticate.

  **We are not an authorization server.** Unlike Khala, we offer no OAuth flow;
  clients use tokens the user created on the settings screen as-is. So we leave
  `authorization_servers` empty and advertise only `bearer_methods_supported` —
  that is the truth.
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
