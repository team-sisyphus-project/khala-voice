defmodule VR.Khala.Connection do
  @moduledoc """
  칼라 계정 연결. **남의 토큰을 우리가 보관한다.**

  자동 발송이 요약이 끝난 뒤(사용자의 브라우저가 닫힌 뒤) 일어나므로 서버가
  토큰을 들고 있어야 한다 (`docs/15-mcp-khala.md`).

  그래서 `access_token` · `refresh_token` 은 `VR.Encrypted.Binary` 로 암호화해
  저장한다. 로그·에러에 실려 나가지 않도록 `@derive` 로 인스펙트에서도 가린다.

  칼라는 **공개 클라이언트**다 (`token_endpoint_auth_methods_supported: ["none"]`).
  client_secret 이 없어서 보관할 것도 없다 — PKCE 가 그 자리를 대신한다.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator

  @derive {Inspect, except: [:access_token, :refresh_token]}

  @primary_key {:id, :string, autogenerate: false}
  schema "khala_connections" do
    field :account_id, :string
    field :client_id, :string

    field :access_token, VR.Encrypted.Binary, source: :access_token_encrypted
    field :refresh_token, VR.Encrypted.Binary, source: :refresh_token_encrypted
    field :expires_at, :utc_datetime

    field :inbox_code, :string
    field :inbox_name, :string

    field :connected_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def build(account_id, attrs) do
    %__MODULE__{}
    |> cast(attrs, [:client_id, :access_token, :refresh_token, :expires_at])
    |> put_change(:id, IdGenerator.generate(:khala_connection))
    |> put_change(:account_id, account_id)
    |> put_change(:connected_at, DateTime.utc_now(:second))
    |> validate_required([:client_id, :access_token])
  end

  @doc "토큰을 갱신한다. 칼라가 refresh_token 을 새로 주지 않으면 쓰던 것을 유지한다."
  def refresh_changeset(connection, attrs) do
    connection
    |> cast(attrs, [:access_token, :refresh_token, :expires_at])
    |> validate_required([:access_token])
  end

  @doc "칼라에 만든 우리 인박스. 보내는 쪽이 된다."
  def inbox_changeset(connection, code, name) do
    change(connection, inbox_code: code, inbox_name: name)
  end

  @doc "연결을 끊는다. 행을 지우지 않는다 — 언제 끊었는지가 남아야 한다."
  def revoke_changeset(connection) do
    change(connection, revoked_at: DateTime.utc_now(:second))
  end
end
