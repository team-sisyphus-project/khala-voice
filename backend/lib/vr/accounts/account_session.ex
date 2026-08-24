defmodule VR.Accounts.AccountSession do
  @moduledoc """
  로그인 세션. 기기 하나당 한 행.

  설정 화면에서 "어느 기기에서 로그인 중인지" 보여주고 원격 로그아웃을 하기 위해
  토큰을 DB에 둔다.

  ## 토큰 취급

  원본 토큰은 **쿠키에만** 있고 DB에는 SHA-256 해시만 저장한다.
  DB가 유출돼도 그것만으로 세션을 탈취할 수 없다.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @rand_size 32
  @validity_days 60

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "account_sessions" do
    field :account_id, :string
    field :token_hash, :binary, redact: true
    field :user_agent, :string
    field :ip_address, :string
    field :last_activity_at, :utc_datetime
    field :mfa_verified_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def validity_days, do: @validity_days

  @doc """
  새 세션을 만든다. `{원본_토큰, changeset}`을 돌려준다.

  원본 토큰은 이 시점 이후로 다시 구할 수 없다. 쿠키에 심고 버린다.
  """
  def build(account_id, attrs \\ %{}) do
    token = :crypto.strong_rand_bytes(@rand_size)
    now = DateTime.utc_now(:second)

    changeset =
      %__MODULE__{}
      |> change(%{
        id: IdGenerator.generate(:account_session),
        account_id: account_id,
        token_hash: :crypto.hash(:sha256, token),
        user_agent: truncate(attrs[:user_agent], 300),
        ip_address: truncate(attrs[:ip_address], 45),
        last_activity_at: now,
        mfa_verified_at: attrs[:mfa_verified_at],
        expires_at: DateTime.add(now, @validity_days, :day),
        is_active: true
      })

    {Base.url_encode64(token, padding: false), changeset}
  end

  @doc "쿠키에 담긴 문자열 토큰을 DB 조회용 해시로 바꾼다."
  def hash_token(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, :crypto.hash(:sha256, raw)}
      :error -> :error
    end
  end

  def hash_token(_), do: :error

  defp truncate(nil, _max), do: nil
  defp truncate(value, max), do: String.slice(to_string(value), 0, max)
end
