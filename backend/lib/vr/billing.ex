defmodule VR.Billing do
  @moduledoc """
  Plans and subscriptions.

  **Source: devkanban** `lib/manualsquad/billing.ex` + `docs/billing-commerce-design.md`.
  Payments, pack purchases, auto top-up, and enterprise contracts were not ported.

  Credits themselves are handled by `VR.Billing.Credits`.
  """

  import Ecto.Query, warn: false

  alias VR.Billing.{Credits, Plan, PlanRevision, Subscription}
  alias VR.Repo

  require Logger

  @free_plan_key "free"

  def free_plan_key, do: @free_plan_key

  # ── Plans ────────────────────────────────────────────────

  def list_plans(opts \\ []) do
    query = from p in Plan, order_by: [asc: p.sort_order, asc: p.key]

    query =
      if opts[:public],
        do: where(query, [p], p.publicly_listed == true and p.status == "published"),
        else: query

    query |> Repo.all() |> Repo.preload(revisions: revision_order())
  end

  def get_plan(id), do: Repo.get(Plan, id) |> preload_revisions()
  def get_plan_by_key(key), do: Repo.get_by(Plan, key: key) |> preload_revisions()

  defp preload_revisions(nil), do: nil
  defp preload_revisions(plan), do: Repo.preload(plan, revisions: revision_order())

  defp revision_order, do: from(r in PlanRevision, order_by: [desc: r.revision])

  def create_plan(attrs) do
    %Plan{} |> Plan.changeset(attrs) |> Repo.insert()
  end

  def update_plan_meta(%Plan{} = plan, attrs) do
    plan |> Plan.meta_changeset(attrs) |> Repo.update()
  end

  @doc "The currently purchasable revision. Falls back to the most recent one."
  def current_revision(%Plan{} = plan) do
    plan = preload_revisions(plan)
    Enum.find(plan.revisions, & &1.purchasable) || List.first(plan.revisions)
  end

  @doc """
  Publishes a new revision.

  **Previous revisions become `purchasable = false`** — new signups go to the new one,
  while existing subscriptions keep their own revision (grandfathering).
  """
  def publish_revision(%Plan{} = plan, attrs) do
    next =
      Repo.one(from r in PlanRevision, where: r.plan_id == ^plan.id, select: max(r.revision))

    next = (next || 0) + 1

    attrs =
      attrs
      |> Map.put(:plan_id, plan.id)
      |> Map.put(:revision, next)
      |> Map.put(:purchasable, true)
      |> Map.put(:published_at, DateTime.utc_now(:second))

    Ecto.Multi.new()
    |> Ecto.Multi.update_all(
      :retire_previous,
      from(r in PlanRevision, where: r.plan_id == ^plan.id and r.purchasable == true),
      set: [purchasable: false]
    )
    |> Ecto.Multi.insert(:revision, PlanRevision.changeset(%PlanRevision{}, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{revision: revision}} -> {:ok, revision}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  # ── Subscriptions ────────────────────────────────────────

  def get_subscription(account_id) do
    Repo.one(
      from s in Subscription,
        where: s.account_id == ^account_id and s.state in ^Subscription.live_states(),
        preload: [plan_revision: :plan]
    )
  end

  @doc """
  Subscribes an account to the free plan right after signup.

  Does nothing if there is no free plan or a subscription already exists —
  **it never blocks signup itself.** Users must not be locked out just because
  billing has not been fully configured.
  """
  def ensure_default_subscription(account_id) do
    cond do
      get_subscription(account_id) ->
        {:ok, :exists}

      true ->
        case get_plan_by_key(@free_plan_key) do
          nil ->
            Logger.warning("[Billing] free plan (#{@free_plan_key}) not found; skipping subscription")
            {:ok, :no_plan}

          plan ->
            case current_revision(plan) do
              nil -> {:ok, :no_revision}
              revision -> subscribe(account_id, revision)
            end
        end
    end
  end

  @doc "Creates a subscription and grants the first period's credits."
  def subscribe(account_id, %PlanRevision{} = revision) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :subscription,
      Subscription.changeset(%Subscription{}, %{
        account_id: account_id,
        plan_revision_id: revision.id
      })
    )
    |> Ecto.Multi.run(:grant, fn _repo, %{subscription: subscription} ->
      grant_period_credits(subscription, revision)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{subscription: subscription}} -> {:ok, subscription}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Grants the credits for this period. They expire at the end of the period (no rollover).

  The period end is baked into the `idempotency_key` so **the same period is never
  granted twice.** Safe even when the worker retries.
  """
  def grant_period_credits(%Subscription{} = subscription, %PlanRevision{} = revision) do
    amount = PlanRevision.granted_credits(revision)

    if amount <= 0 do
      {:ok, :nothing_to_grant}
    else
      key = "plan_grant:#{subscription.id}:#{DateTime.to_unix(subscription.current_period_end)}"

      case Credits.grant(subscription.account_id, amount,
             source: "plan_grant",
             expires_at: DateTime.truncate(subscription.current_period_end, :microsecond),
             reason: "Plan period grant",
             idempotency_key: key,
             origin: %{
               "subscription_id" => subscription.id,
               "plan_revision_id" => revision.id
             }
           ) do
        {:ok, lot} -> {:ok, lot}
        {:error, :already_granted} -> {:ok, :already_granted}
        error -> error
      end
    end
  end

  @doc "Advances the subscription to the next period and grants credits. Used by the monthly grant worker."
  def advance_period(%Subscription{} = subscription) do
    subscription = Repo.preload(subscription, :plan_revision)
    revision = subscription.plan_revision

    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :subscription,
      Subscription.advance_period_changeset(subscription, revision.interval)
    )
    |> Ecto.Multi.run(:grant, fn _repo, %{subscription: advanced} ->
      grant_period_credits(advanced, revision)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{subscription: advanced}} -> {:ok, advanced}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Active subscriptions whose period has ended. Scanned by the monthly grant worker."
  def list_due_subscriptions(now \\ nil) do
    now = now || DateTime.utc_now(:second)

    Repo.all(
      from s in Subscription,
        where: s.state == "active" and s.current_period_end <= ^now,
        preload: [:plan_revision]
    )
  end

  @doc "A bundle of the account's billing state. Used as-is by the UI."
  def account_summary(account_id) do
    subscription = get_subscription(account_id)

    %{
      subscription: subscription,
      plan: subscription && subscription.plan_revision.plan,
      revision: subscription && subscription.plan_revision,
      balance: Credits.balance(account_id),
      lots: Credits.list_lots(account_id)
    }
  end
end
