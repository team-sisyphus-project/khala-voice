defmodule VR.Accounts.AccountToken do
  @moduledoc """
  일회성 이메일 토큰 — 이메일 확인, 비밀번호 재설정, 이메일 변경.

  세션과 마찬가지로 원본은 메일 링크에만 있고 DB에는 해시만 둔다.

  ## 컨텍스트별 유효기간

  | 컨텍스트 | 유효 |
  |---|---|
  | `confirm` | 7일 |
  | `reset_password` | 1시간 |
  | `change_email` | 1일 |

  비밀번호 재설정이 짧은 이유: 메일함이 털렸을 때의 노출 창을 줄이기 위해서다.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @rand_size 32

  @validity %{
    "confirm" => {7, :day},
    "reset_password" => {1, :hour},
    "change_email" => {1, :day}
  }

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "account_tokens" do
    field :account_id, :string
    field :token_hash, :binary, redact: true
    field :context, :string
    field :sent_to, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def contexts, do: Map.keys(@validity)

  @doc "`{원본_토큰, changeset}`을 돌려준다. 원본은 메일 링크에만 쓴다."
  def build(account_id, context, sent_to) when is_map_key(@validity, context) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {amount, unit} = @validity[context]
    now = DateTime.utc_now(:second)

    changeset =
      %__MODULE__{}
      |> change(%{
        id: IdGenerator.generate(:account_token),
        account_id: account_id,
        token_hash: :crypto.hash(:sha256, token),
        context: context,
        sent_to: sent_to,
        expires_at: DateTime.add(now, amount, unit)
      })

    {Base.url_encode64(token, padding: false), changeset}
  end

  def hash_token(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, :crypto.hash(:sha256, raw)}
      :error -> :error
    end
  end

  def hash_token(_), do: :error
end
