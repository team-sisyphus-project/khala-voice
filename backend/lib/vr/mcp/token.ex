defmodule VR.MCP.Token do
  @moduledoc """
  A token that can read our MCP server.

  **The plaintext exists only at the moment of issuance.** Only the hash is
  stored; if lost, create a new one — the same approach as share links
  (`VR.Sharing.SharedLink`). If tokens sat in the DB as plaintext, anyone who
  can read the DB could read every archive.

  The scope is **archive read-only** (`docs/15-mcp-khala.md`). We grant no
  write, delete, or audio access, so there is no scope field — a field would
  eventually get filled in, and from then on "what can this token do" becomes
  something you have to read the code to know.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator

  @token_prefix "mcp_"
  @rand_size 32
  # Leading characters used to recognize the token in lists. Not enough to reconstruct it.
  @visible 10

  @primary_key {:id, :string, autogenerate: false}
  schema "mcp_tokens" do
    field :account_id, :string
    field :name, :string
    field :token_hash, :binary
    field :token_prefix, :string
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def token_prefix, do: @token_prefix

  @doc """
  A new token. Returns `{plaintext, changeset}`.

  The plaintext can never be recovered after this point.
  """
  def build(account_id, attrs \\ %{}) do
    raw = :crypto.strong_rand_bytes(@rand_size)
    token = @token_prefix <> Base.url_encode64(raw, padding: false)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:name, :expires_at])
      |> put_change(:id, IdGenerator.generate(:mcp_token))
      |> put_change(:account_id, account_id)
      |> put_change(:token_hash, hash(token))
      |> put_change(:token_prefix, String.slice(token, 0, @visible))
      |> validate_required([:name])
      |> validate_length(:name, max: 60)

    {token, changeset}
  end

  @doc "The hash of a plaintext token. Lookups use only this value."
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)
end
