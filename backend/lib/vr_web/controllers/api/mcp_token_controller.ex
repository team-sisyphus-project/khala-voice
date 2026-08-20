defmodule VRWeb.API.MCPTokenController do
  @moduledoc """
  MCP 읽기 토큰 발급·조회·취소.

  **평문은 발급 응답에 한 번만 실린다.** 목록에는 앞자리만 나온다 —
  공유 링크와 같은 방식이다 (`docs/05-auth-sharing.md`).
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
      # `token` 은 지금만 볼 수 있다. 다시 못 준다.
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
