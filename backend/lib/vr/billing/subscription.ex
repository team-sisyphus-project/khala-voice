defmodule VR.Billing.Subscription do
  @moduledoc """
  An account's contract. **Pins a specific `PlanRevision`.**

  **Source: devkanban** `lib/manualsquad/billing/subscription.ex`
  — replaced `organization_id` with `account_id` and trimmed the payment fields.

  Pinning makes grandfathering automatic. Even when a new revision is published,
  this subscription keeps looking at its own revision. Moving it requires an
  **explicit migration.**
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.Billing.PlanRevision
  alias VR.IdGenerator

  @states ~w(active past_due paused canceled)
  # These states count as a "live" subscription. Only one is allowed per account.
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

  @doc "Advances to the next period. Used by the monthly grant worker."
  def advance_period_changeset(%__MODULE__{} = subscription, interval) do
    start = subscription.current_period_end

    change(subscription, %{
      current_period_start: start,
      current_period_end: add_interval(start, interval)
    })
  end

  @doc "Computes the period end. A month is fixed at 30 days — same rule as devkanban."
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
      add_error(changeset, :current_period_end, "must be after the period start")
    else
      changeset
    end
  end
end
