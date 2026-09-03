defmodule VRWeb.MCPAuth do
  @moduledoc """
  Bearer token authentication for the MCP server.

  ## What goes into the 401

  Per RFC 9728, the `WWW-Authenticate` header carries the resource metadata URL.
  MCP clients use it to figure out how to authenticate — the same way Khala
  does with us.

  ## Why 401 instead of 404

  This app's rule is "no access means 404" (`docs/05-auth-sharing.md`), but that
  is about **hiding which resources exist**. Here we are dealing with a protocol
  entry point rather than a resource, and the client needs to learn how to
  authenticate, so 401 is correct. Access decisions for individual meetings
  behind this point still answer with 404.
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
          message: "Authentication required. Create a read token under Settings → Integrations."
        }
      })
    )
    |> halt()
  end
end
