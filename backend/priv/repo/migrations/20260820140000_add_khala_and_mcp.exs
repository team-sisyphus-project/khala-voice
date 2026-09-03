defmodule VR.Repo.Migrations.AddKhalaAndMcp do
  use Ecto.Migration

  @moduledoc """
  Khala integration (export) and our MCP server (read tokens).

  **Two things pointing in opposite directions** (`docs/15-mcp-khala.md`):

    khala_connections  us → Khala   we hold someone else's token, obtained via OAuth
    mcp_tokens         them → us    we hold only hashes of tokens we issued

  So the storage is opposite too. Khala tokens are kept encrypted because
  **we must use them again**; our own tokens only need **comparison**, so we
  keep just the hash.
  """

  def change do
    create table(:khala_connections, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false

      # client_id from OAuth dynamic registration. Public client, so no secret.
      add :client_id, :string, null: false

      # Encrypted because we must use the value again (`VR.Encrypted.Binary`)
      add :access_token_encrypted, :binary, null: false
      add :refresh_token_encrypted, :binary
      add :expires_at, :utc_datetime

      # Our inbox created on Khala. This is the sending side (sender_inbox_code).
      add :inbox_code, :string
      add :inbox_name, :string

      add :connected_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One per account. Allowing several blurs "which one did we send with".
    create unique_index(:khala_connections, [:account_id], where: "revoked_at IS NULL")

    create table(:mcp_tokens, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false

      add :name, :string, null: false
      # Plaintext is shown only at issue time — same approach as shared links
      add :token_hash, :binary, null: false
      # For telling tokens apart in lists. The rest cannot be recovered.
      add :token_prefix, :string, null: false

      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mcp_tokens, [:token_hash])
    create index(:mcp_tokens, [:account_id])
  end
end
