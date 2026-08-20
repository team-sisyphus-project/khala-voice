defmodule VR.Sharing.ShareAttempt do
  @moduledoc """
  공유 링크 PIN 입력 시도.

  **출처: 이 리포의 `VR.Accounts.LoginAttempt`** 와 같은 모양.
  `login_attempts` 를 재사용하지 않는다 — 그 테이블의 `email` 컬럼 의미가 흐려진다.

  IP 기준 대입을 막는 데 쓴다. 링크별 잠금만 두면 공격자가 여러 링크를
  번갈아 때리는 것을 못 막는다.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "share_attempts" do
    field :token_hash, :binary, redact: true
    field :ip_address, :string
    field :success, :boolean, default: false
    field :attempted_at, :utc_datetime
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:token_hash, :ip_address, :success])
    |> put_change(:attempted_at, DateTime.utc_now(:second))
  end
end
