defmodule VR.Repo.Migrations.AddKhalaAndMcp do
  use Ecto.Migration

  @moduledoc """
  칼라 연동(내보내기)과 우리 MCP 서버(읽기 토큰).

  **방향이 반대인 두 가지다** (`docs/15-mcp-khala.md`):

    khala_connections  우리 → 칼라   OAuth 로 받은 남의 토큰을 우리가 보관
    mcp_tokens         남 → 우리     우리가 발급한 토큰의 해시만 보관

  그래서 저장 방식도 반대다. 칼라 토큰은 **우리가 다시 써야 해서** 암호화해
  보관하고, 우리 토큰은 **대조만 하면 되므로** 해시만 남긴다.
  """

  def change do
    create table(:khala_connections, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false

      # OAuth 동적 등록으로 받은 client_id. 공개 클라이언트라 secret 은 없다.
      add :client_id, :string, null: false

      # 우리가 다시 써야 하는 값이라 암호화해 둔다 (`VR.Encrypted.Binary`)
      add :access_token_encrypted, :binary, null: false
      add :refresh_token_encrypted, :binary
      add :expires_at, :utc_datetime

      # 칼라에 만든 우리 인박스. 보내는 쪽(sender_inbox_code)이 이것이다.
      add :inbox_code, :string
      add :inbox_name, :string

      add :connected_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # 계정당 하나. 여러 개를 허용하면 "어느 것으로 보냈나"가 흐려진다.
    create unique_index(:khala_connections, [:account_id], where: "revoked_at IS NULL")

    create table(:mcp_tokens, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false

      add :name, :string, null: false
      # 평문은 발급 순간에만 보여준다 — 공유 링크와 같은 방식
      add :token_hash, :binary, null: false
      # 목록에서 어느 토큰인지 알아보는 용도. 뒤는 못 복원한다.
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
