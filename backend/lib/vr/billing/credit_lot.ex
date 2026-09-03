defmodule VR.Billing.CreditLot do
  @moduledoc """
  A granted batch of credits, with its own remaining amount and expiry.

  **Source: devkanban** `lib/manualsquad/billing/credit_lot.ex`
  — removed `held` / `held_amount` (refund holds).

  Credits are split into lots because **each lot expires differently.**
  Monthly plan grants expire at the end of the period, while admin grants may be
  indefinite. Consumption goes soonest-expiring first, so credits about to vanish
  are spent first.

  `remaining` **can go negative** — when post-hoc metering finds the balance short,
  the shortfall is recorded as an overdraft lot. That keeps `Σ delta == Σ remaining`.
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

  @doc "The amount still spendable. Negative (overdraft) counts as 0."
  def spendable(%__MODULE__{remaining: remaining}), do: max(remaining, 0)

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:credit_lot))
      "" -> put_change(changeset, :id, IdGenerator.generate(:credit_lot))
      _ -> changeset
    end
  end
end
