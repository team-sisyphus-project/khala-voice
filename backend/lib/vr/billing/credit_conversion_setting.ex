defmodule VR.Billing.CreditConversionSetting do
  @moduledoc """
  **Singleton** policy that converts usage cost (USD) into internal credits.

  **Source: devkanban** `lib/manualsquad/billing/credit_conversion_setting.ex` — as-is.

  sisyphus kept a separate `cookie_rate` per service. That meant recalculating each
  service's conversion rate whenever a provider's unit price changed. This approach
  is **derived from the actual USD cost**, so a price change only requires fixing the
  cost calculation, and the credit policy lives in this one place.

      computed_credits = usage_cost_usd / credit_value_usd
      charged_credits  = ceil(computed_credits)

  Why ceiling is fixed: a single policy keeps things simple and never leaks fractions.
  devkanban likewise pinned `rounding_policies` to just `["ceil"]`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @rounding_policy "ceil"
  @singleton_key "current"

  @primary_key {:id, :string, autogenerate: false}

  schema "credit_conversion_settings" do
    field :singleton_key, :string, default: @singleton_key
    field :currency, :string, default: "USD"
    field :credit_value_usd, :decimal
    field :rounding_policy, :string, default: @rounding_policy
    field :updated_by_id, :string

    timestamps(type: :utc_datetime)
  end

  def rounding_policy, do: @rounding_policy
  def singleton_key, do: @singleton_key

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:credit_value_usd, :updated_by_id])
    |> put_id()
    |> put_change(:singleton_key, @singleton_key)
    |> put_change(:currency, "USD")
    |> put_change(:rounding_policy, @rounding_policy)
    |> validate_required([:id, :credit_value_usd])
    |> validate_number(:credit_value_usd, greater_than: 0)
    |> unique_constraint(:singleton_key)
    |> check_constraint(:credit_value_usd, name: :credit_value_positive)
  end

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:credit_conversion_setting))
      "" -> put_change(changeset, :id, IdGenerator.generate(:credit_conversion_setting))
      _ -> changeset
    end
  end
end
