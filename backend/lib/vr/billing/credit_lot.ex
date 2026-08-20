defmodule VR.Billing.CreditLot do
  @moduledoc """
  지급된 크레딧 묶음. 자체 잔량과 만료를 가진다.

  **출처: devkanban** `lib/manualsquad/billing/credit_lot.ex`
  — `held` / `held_amount` (환불 보류) 를 제거했다.

  묶음으로 나누는 이유는 **만료가 각각 다르기 때문**이다.
  플랜 월 지급은 기간 말에 만료되고, 관리자 지급은 무기한일 수 있다.
  소비는 만료 임박 순으로 하므로 사라질 크레딧이 먼저 쓰인다.

  `remaining` 은 **음수가 될 수 있다** — 사후 계량에서 잔액이 모자랄 때
  오버드래프트 묶음으로 기록한다. 그래야 `Σ delta == Σ remaining` 이 유지된다.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @sources ~w(plan_grant admin_grant overdraft)

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "credit_lots" do
    field :account_id, :string
    field :source, :string
    field :amount, :integer
    field :remaining, :integer
    field :expires_at, :utc_datetime_usec
    field :expired_at, :utc_datetime_usec
    field :origin, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def sources, do: @sources

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:account_id, :source, :amount, :remaining, :expires_at, :expired_at, :origin])
    |> put_id()
    |> validate_required([:id, :account_id, :source, :amount, :remaining])
    |> validate_inclusion(:source, @sources)
  end

  @doc "아직 쓸 수 있는 양. 음수(오버드래프트)는 0으로 본다."
  def spendable(%__MODULE__{remaining: remaining}), do: max(remaining, 0)

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:credit_lot))
      "" -> put_change(changeset, :id, IdGenerator.generate(:credit_lot))
      _ -> changeset
    end
  end
end
