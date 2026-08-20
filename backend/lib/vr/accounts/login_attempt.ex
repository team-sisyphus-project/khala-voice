defmodule VR.Accounts.LoginAttempt do
  @moduledoc """
  로그인 시도 기록. 무차별 대입을 늦추는 데 쓴다.

  이메일과 IP를 **각각** 센다. 한쪽만 보면 우회가 쉽다.

  - 한 이메일에 대한 반복 시도 → 그 계정을 노린 공격
  - 한 IP에서 여러 이메일 시도 → 크리덴셜 스터핑
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "login_attempts" do
    field :email, :string
    field :ip_address, :string
    field :success, :boolean, default: false
    field :attempted_at, :utc_datetime
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:email, :ip_address, :success])
    |> put_change(:attempted_at, DateTime.utc_now(:second))
  end
end
