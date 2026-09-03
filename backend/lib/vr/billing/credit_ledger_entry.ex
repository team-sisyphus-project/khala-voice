defmodule VR.Billing.CreditLedgerEntry do
  @moduledoc """
  Record of credit changes. **Append-only.**

  **Source: devkanban** `lib/manualsquad/billing/credit_ledger_entry.ex`
  — removed the refund/chargeback sources and metering record references.

  Balances are never mutated directly, **for the sake of auditability.**
  We must be able to trace "why is the credit balance what it is" at any time,
  which requires keeping the process, not just the result.

      balance = Σ delta = Σ lot.remaining
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

    # Usage details — kept so the charge can be recomputed later
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

  # A usage entry without cost evidence cannot be recomputed later
  defp validate_usage_details(changeset) do
    if get_field(changeset, :source) == "usage" do
      validate_required(changeset, [:charge_domain, :usage_cost_usd, :credit_value_usd],
        message: "usage entries require cost evidence"
      )
    else
      changeset
    end
  end
end
