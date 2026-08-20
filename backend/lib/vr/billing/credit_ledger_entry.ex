defmodule VR.Billing.CreditLedgerEntry do
  @moduledoc """
  크레딧 증감 기록. **append-only.**

  **출처: devkanban** `lib/manualsquad/billing/credit_ledger_entry.ex`
  — 환불 · 역결제 소스와 계량 레코드 참조를 제거했다.

  잔액을 직접 고치지 않는 이유는 **감사 때문**이다.
  "왜 크레딧이 이만큼인가"를 언제든 되짚을 수 있어야 하고,
  그러려면 결과가 아니라 과정이 남아야 한다.

      잔액 = Σ delta = Σ lot.remaining
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @sources ~w(plan_grant admin_grant usage expiry admin_revoke adjustment)

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "credit_ledger_entries" do
    field :account_id, :string
    field :credit_lot_id, :string
    field :delta, :integer
    field :source, :string
    field :reason, :string
    field :actor_id, :string
    field :idempotency_key, :string

    # 사용(usage) 상세 — 나중에 재계산할 수 있게 남긴다
    field :charge_domain, :string
    field :usage_cost_usd, :decimal
    field :credit_value_usd, :decimal
    field :computed_credits, :decimal
    field :charged_credits, :integer
    field :rounding_policy, :string
    field :pricing_snapshot, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def sources, do: @sources

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :account_id,
      :credit_lot_id,
      :delta,
      :source,
      :reason,
      :actor_id,
      :idempotency_key,
      :charge_domain,
      :usage_cost_usd,
      :credit_value_usd,
      :computed_credits,
      :charged_credits,
      :rounding_policy,
      :pricing_snapshot
    ])
    |> put_id()
    |> validate_required([:id, :account_id, :delta, :source])
    |> validate_inclusion(:source, @sources)
    |> validate_usage_details()
    |> unique_constraint(:idempotency_key)
  end

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:credit_ledger_entry))
      "" -> put_change(changeset, :id, IdGenerator.generate(:credit_ledger_entry))
      _ -> changeset
    end
  end

  # 사용 기록인데 근거가 없으면 나중에 재계산할 수 없다
  defp validate_usage_details(changeset) do
    if get_field(changeset, :source) == "usage" do
      validate_required(changeset, [:charge_domain, :usage_cost_usd, :credit_value_usd],
        message: "사용 기록에는 원가 근거가 필요합니다"
      )
    else
      changeset
    end
  end
end
