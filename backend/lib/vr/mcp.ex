defmodule VR.MCP do
  @moduledoc """
  우리 MCP 서버 — **외부가 우리 아카이브를 읽는 쪽**.

  반대 방향(우리가 칼라에게 보내는 것)은 `VR.Khala` 다.
  설계는 [`docs/15-mcp-khala.md`](../../docs/15-mcp-khala.md).

  ## 토큰

  평문은 발급 순간에만 존재하고 해시만 저장한다 (`VR.MCP.Token`).
  조회는 늘 해시로 한다.
  """

  import Ecto.Query

  alias VR.MCP.Token
  alias VR.Repo

  @doc "새 토큰. `{평문, 토큰}` — 평문은 다시 구할 수 없다."
  def issue_token(account_id, attrs \\ %{}) do
    {plain, changeset} = Token.build(account_id, attrs)

    case Repo.insert(changeset) do
      {:ok, token} -> {:ok, plain, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "이 계정의 살아 있는 토큰들. 평문은 없다."
  def list_tokens(account_id) do
    Repo.all(
      from t in Token,
        where: t.account_id == ^account_id and is_nil(t.revoked_at),
        order_by: [desc: t.inserted_at]
    )
  end

  @doc "토큰을 끊는다. 행은 남긴다 — 언제 끊었는지가 기록이다."
  def revoke_token(account_id, id) do
    case Repo.one(from t in Token, where: t.id == ^id and t.account_id == ^account_id) do
      nil ->
        {:error, :not_found}

      token ->
        token |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update()
    end
  end

  @doc """
  평문 토큰으로 계정을 찾는다.

  **만료·취소된 토큰은 없는 것과 같다.** 왜 거절됐는지 구분해 알려주지 않는다 —
  구분하면 "그 토큰은 있었다"는 사실이 새어 나간다.
  """
  def authenticate(plain) when is_binary(plain) do
    hash = Token.hash(plain)
    now = DateTime.utc_now()

    query =
      from t in Token,
        where: t.token_hash == ^hash and is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      nil ->
        :error

      token ->
        # 마지막 사용 시각은 기록해 둔다. 안 쓰는 토큰을 지울 근거가 된다.
        # 실패해도 인증을 막지 않는다.
        _ =
          Repo.update_all(from(t in Token, where: t.id == ^token.id),
            set: [last_used_at: DateTime.utc_now(:second)]
          )

        {:ok, token.account_id}
    end
  end

  def authenticate(_), do: :error
end
