defmodule VR.Billing.Subscription do
  @moduledoc """
  계정이 가진 계약. **특정 `PlanRevision` 을 핀 고정한다.**

  **출처: devkanban** `lib/manualsquad/billing/subscription.ex`
  — `organization_id` 를 `account_id` 로 바꾸고 결제 관련 필드를 축소했다.

  핀 고정이 그랜드파더링을 자동으로 만든다. 새 리비전이 발행돼도
  이 구독은 자기 리비전을 계속 본다. 옮기려면 **명시적 마이그레이션**이 필요하다.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.Billing.PlanRevision
  alias VR.IdGenerator

  @states ~w(active past_due paused canceled)
  # 이 상태들은 "살아있는" 구독으로 본다. 계정당 하나만 허용된다.
  @live_states ~w(active past_due paused)

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "subscriptions" do
    field :account_id, :string
    field :state, :string, default: "active"
    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime
    field :cancel_at, :utc_datetime
    field :scheduled_change, :map

    field :provider, :string
    field :provider_subscription_id, :string

    belongs_to :plan_revision, PlanRevision

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def live_states, do: @live_states

  def live?(%__MODULE__{state: state}), do: state in @live_states

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :account_id,
      :plan_revision_id,
      :state,
      :current_period_start,
      :current_period_end,
      :cancel_at,
      :scheduled_change,
      :provider,
      :provider_subscription_id
    ])
    |> put_id()
    |> put_period()
    |> validate_required([:id, :account_id, :plan_revision_id])
    |> validate_inclusion(:state, @states)
    |> validate_period()
    |> unique_constraint(:account_id, name: :subscriptions_one_active_per_account)
    |> foreign_key_constraint(:plan_revision_id)
  end

  @doc "기간을 다음으로 넘긴다. 월 지급 워커가 쓴다."
  def advance_period_changeset(%__MODULE__{} = subscription, interval) do
    start = subscription.current_period_end

    change(subscription, %{
      current_period_start: start,
      current_period_end: add_interval(start, interval)
    })
  end

  @doc "기간 끝을 계산한다. 월은 30일 고정 — devkanban 과 같은 규칙."
  def add_interval(%DateTime{} = from, "year"), do: DateTime.add(from, 365, :day)
  def add_interval(%DateTime{} = from, _month), do: DateTime.add(from, 30, :day)

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:subscription))
      "" -> put_change(changeset, :id, IdGenerator.generate(:subscription))
      _ -> changeset
    end
  end

  defp put_period(changeset) do
    if get_field(changeset, :current_period_start) do
      changeset
    else
      now = DateTime.utc_now(:second)

      changeset
      |> put_change(:current_period_start, now)
      |> put_change(:current_period_end, add_interval(now, "month"))
    end
  end

  defp validate_period(changeset) do
    start = get_field(changeset, :current_period_start)
    finish = get_field(changeset, :current_period_end)

    if start && finish && DateTime.compare(finish, start) != :gt do
      add_error(changeset, :current_period_end, "기간 끝이 시작보다 뒤여야 합니다")
    else
      changeset
    end
  end
end
