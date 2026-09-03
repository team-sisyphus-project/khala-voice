defmodule VRWeb.API.MCPTokenController do
  @moduledoc """
  MCP read-token issuance, listing, and revocation.

  **The plaintext token appears exactly once, in the issuance response.** Listings
  show only the prefix — the same scheme as share links (`docs/05-auth-sharing.md`).
  """

  use VRWeb, :controller

  alias VR.MCP

  action_fallback VRWeb.API.FallbackController

  def index(conn, _params) do
    account = conn.assigns.current_account
    json(conn, %{tokens: Enum.map(MCP.list_tokens(account.id), &view/1)})
  end

  def create(conn, params) do
    account = conn.assigns.current_account
    attrs = Map.take(params, ["name", "expires_at"])

    with {:ok, plain, token} <- MCP.issue_token(account.id, attrs) do
      conn
      |> put_status(:created)
      # `token` is visible only now. It cannot be shown again.
      |> json(Map.put(view(token), :token, plain))
    end
  end

  def delete(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with {:ok, _} <- MCP.revoke_token(account.id, id) do
      send_resp(conn, :no_content, "")
    end
  end

  defp view(token) do
    %{
      id: token.id,
      name: token.name,
      token_prefix: token.token_prefix,
      last_used_at: token.last_used_at,
      expires_at: token.expires_at,
      inserted_at: token.inserted_at
    }
  end
end
