defmodule VR.Billing.CreditConversionSetting do
  @moduledoc """
  사용 원가(USD)를 내부 크레딧으로 바꾸는 **싱글턴** 정책.

  **출처: devkanban** `lib/manualsquad/billing/credit_conversion_setting.ex` — 그대로.

  sisyphus 는 서비스마다 `cookie_rate` 를 따로 뒀다. 그러면 제공자 단가가 바뀔 때마다
  서비스별 환산율을 다시 계산해야 한다. 이 방식은 **실제 USD 원가에서 파생**되므로
  단가가 바뀌어도 원가 계산만 고치면 되고, 크레딧 정책은 여기 한 곳에만 있다.

      computed_credits = usage_cost_usd / credit_value_usd
      charged_credits  = ceil(computed_credits)

  올림 고정인 이유: 정책이 하나뿐이라 단순하고 소수점 이하를 흘리지 않는다.
  devkanban 도 `rounding_policies` 를 `["ceil"]` 하나로 못박아 뒀다.
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
