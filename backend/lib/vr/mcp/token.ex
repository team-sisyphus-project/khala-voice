defmodule VR.MCP.Token do
  @moduledoc """
  우리 MCP 서버를 읽을 수 있는 토큰.

  **평문은 발급 순간에만 존재한다.** 해시만 저장하고, 잃어버리면 새로 만든다 —
  공유 링크(`VR.Sharing.SharedLink`)와 같은 방식이다. 토큰이 DB 에 평문으로
  있으면 DB 를 읽을 수 있는 사람이 곧 모든 아카이브를 읽을 수 있는 사람이 된다.

  범위는 **아카이브 읽기 전용**이다 (`docs/15-mcp-khala.md`). 쓰기·삭제·오디오를
  주지 않으므로 스코프 필드를 두지 않는다 — 필드가 있으면 언젠가 채우게 되고,
  그때부터 "이 토큰으로 무엇을 할 수 있나"가 코드를 읽어야 알 수 있는 것이 된다.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator

  @token_prefix "mcp_"
  @rand_size 32
  # 목록에서 알아보는 데 쓸 앞자리. 이것만으로는 복원할 수 없다.
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
  새 토큰. `{평문, changeset}` 을 돌려준다.

  평문은 이 시점 이후로 다시 구할 수 없다.
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

  @doc "평문 토큰의 해시. 조회는 이 값으로만 한다."
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)
end
