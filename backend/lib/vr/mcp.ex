defmodule VR.MCP do
  @moduledoc """
  Our MCP server — **the side where external parties read our archive**.

  The opposite direction (us sending to Khala) is `VR.Khala`.
  Design notes: [`docs/15-mcp-khala.md`](../../docs/15-mcp-khala.md).

  ## Tokens

  The plaintext exists only at the moment of issuance; only the hash is stored
  (`VR.MCP.Token`). Lookups are always by hash.
  """

  import Ecto.Query

  alias VR.MCP.Token
  alias VR.Repo

  @doc "A new token. `{plaintext, token}` — the plaintext can never be recovered."
  def issue_token(account_id, attrs \\ %{}) do
    {plain, changeset} = Token.build(account_id, attrs)

    case Repo.insert(changeset) do
      {:ok, token} -> {:ok, plain, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "The live tokens for this account. No plaintext."
  def list_tokens(account_id) do
    Repo.all(
      from t in Token,
        where: t.account_id == ^account_id and is_nil(t.revoked_at),
        order_by: [desc: t.inserted_at]
    )
  end

  @doc "Revoke a token. The row is kept — when it was revoked is part of the record."
  def revoke_token(account_id, id) do
    case Repo.one(from t in Token, where: t.id == ^id and t.account_id == ^account_id) do
      nil ->
        {:error, :not_found}

      token ->
        token |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update()
    end
  end

  @doc """
  Find the account for a plaintext token.

  **An expired or revoked token is treated as nonexistent.** We do not say why
  it was rejected — distinguishing would leak the fact that "that token existed".
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
        # Record the last-used time. It becomes the basis for pruning unused tokens.
        # Failure here does not block authentication.
        _ =
          Repo.update_all(from(t in Token, where: t.id == ^token.id),
            set: [last_used_at: DateTime.utc_now(:second)]
          )

        {:ok, token.account_id}
    end
  end

  def authenticate(_), do: :error
end
