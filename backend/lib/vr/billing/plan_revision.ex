defmodule VR.Billing.PlanRevision do
  @moduledoc """
  플랜의 **불변** 상업 스냅샷.

  **출처: devkanban** `lib/manualsquad/billing/plan_revision.ex`
  — 런타임 초 · 동시실행 수 · 크레딧 팩 연결을 제거했다.

  한 번 발행하면 고치지 않는다. 가격이나 포함 크레딧을 바꾸려면 **새 리비전을 발행**한다.
  구독은 특정 리비전을 핀 고정하므로 기존 계약은 그대로 유지된다.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.Billing.Plan
  alias VR.IdGenerator

  @intervals ~w(month year)

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "plan_revisions" do
    field :revision, :integer
    # 통화별 가격. %{"KRW" => %{"amount" => 0}} — minor unit (원, 센트)
    field :prices, :map, default: %{}
    field :interval, :string, default: "month"
    # 매 기간 지급하는 크레딧
    field :included_credits, :integer, default: 0
    field :limits, :map, default: %{}
    field :purchasable, :boolean, default: true
    field :published_at, :utc_datetime

    belongs_to :plan, Plan

    timestamps(type: :utc_datetime)
  end

  def intervals, do: @intervals

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :plan_id,
      :revision,
      :prices,
      :interval,
      :included_credits,
      :limits,
      :purchasable,
      :published_at
    ])
    |> put_id()
    |> validate_required([:id, :plan_id, :revision])
    |> validate_inclusion(:interval, @intervals)
    |> validate_number(:included_credits, greater_than_or_equal_to: 0)
    |> validate_prices()
    |> unique_constraint([:plan_id, :revision])
    |> foreign_key_constraint(:plan_id)
  end

  @doc """
  이 리비전이 지급하는 크레딧.

  **출처: devkanban** `plan_revision.ex:102` `granted_credits/1`.
  devkanban 은 크레딧 팩 연결도 함께 봤지만 이 앱은 팩이 없어 `included_credits` 뿐이다.
  """
  def granted_credits(%__MODULE__{included_credits: credits}) when is_integer(credits),
    do: credits

  def granted_credits(_revision), do: 0

  @doc "이 통화의 가격(minor unit). 없으면 nil."
  def price(%__MODULE__{prices: prices}, currency) do
    case prices do
      %{^currency => %{"amount" => amount}} when is_integer(amount) -> amount
      _ -> nil
    end
  end

  @doc "무료 리비전인가 — 모든 통화에서 0."
  def free?(%__MODULE__{prices: prices}) when map_size(prices) == 0, do: true

  def free?(%__MODULE__{prices: prices}) do
    Enum.all?(prices, fn {_currency, entry} -> Map.get(entry, "amount", 0) == 0 end)
  end

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:plan_revision))
      "" -> put_change(changeset, :id, IdGenerator.generate(:plan_revision))
      _ -> changeset
    end
  end

  # 가격 맵의 형태가 깨지면 결제 화면 전체가 망가진다. 저장 전에 막는다.
  defp validate_prices(changeset) do
    case get_field(changeset, :prices) do
      prices when is_map(prices) ->
        valid? =
          Enum.all?(prices, fn
            {currency, %{"amount" => amount}} when is_binary(currency) and is_integer(amount) ->
              amount >= 0

            _ ->
              false
          end)

        if valid?,
          do: changeset,
          else: add_error(changeset, :prices, ~s(%{"KRW" => %{"amount" => 0}} 형태여야 합니다))

      _ ->
        add_error(changeset, :prices, "맵이어야 합니다")
    end
  end
end
