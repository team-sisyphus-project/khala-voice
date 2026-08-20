defmodule VR.Billing do
  @moduledoc """
  플랜 · 구독.

  **출처: devkanban** `lib/manualsquad/billing.ex` + `docs/billing-commerce-design.md`.
  결제 · 팩 구매 · 오토충전 · 엔터프라이즈 계약은 이식하지 않았다.

  크레딧 자체는 `VR.Billing.Credits` 가 다룬다.
  """

  import Ecto.Query, warn: false

  alias VR.Billing.{Credits, Plan, PlanRevision, Subscription}
  alias VR.Repo

  require Logger

  @free_plan_key "free"

  def free_plan_key, do: @free_plan_key

  # ── 플랜 ─────────────────────────────────────────────────

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

  @doc "현재 구매 가능한 리비전. 없으면 가장 최근 것."
  def current_revision(%Plan{} = plan) do
    plan = preload_revisions(plan)
    Enum.find(plan.revisions, & &1.purchasable) || List.first(plan.revisions)
  end

  @doc """
  새 리비전을 발행한다.

  **이전 리비전은 `purchasable = false` 가 된다** — 신규 가입은 새 것으로 가고,
  기존 구독은 자기 리비전을 유지한다 (그랜드파더링).
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

  # ── 구독 ─────────────────────────────────────────────────

  def get_subscription(account_id) do
    Repo.one(
      from s in Subscription,
        where: s.account_id == ^account_id and s.state in ^Subscription.live_states(),
        preload: [plan_revision: :plan]
    )
  end

  @doc """
  가입 직후 무료 플랜에 구독시킨다.

  무료 플랜이 없거나 이미 구독이 있으면 아무것도 하지 않는다 —
  **가입 자체를 막지 않는다.** 요금 설정이 덜 됐다고 사용자가 못 들어오면 안 된다.
  """
  def ensure_default_subscription(account_id) do
    cond do
      get_subscription(account_id) ->
        {:ok, :exists}

      true ->
        case get_plan_by_key(@free_plan_key) do
          nil ->
            Logger.warning("[Billing] 무료 플랜(#{@free_plan_key})이 없어 구독을 건너뜁니다")
            {:ok, :no_plan}

          plan ->
            case current_revision(plan) do
              nil -> {:ok, :no_revision}
              revision -> subscribe(account_id, revision)
            end
        end
    end
  end

  @doc "구독을 만들고 첫 기간 크레딧을 지급한다."
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
  이 기간의 크레딧을 지급한다. 기간 말에 만료된다 (이월 없음).

  `idempotency_key` 에 기간 끝을 넣어 **같은 기간에 두 번 지급되지 않게** 한다.
  워커가 재시도돼도 안전하다.
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
             reason: "플랜 기간 지급",
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

  @doc "구독을 다음 기간으로 넘기고 크레딧을 지급한다. 월 지급 워커가 쓴다."
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

  @doc "기간이 끝난 활성 구독. 월 지급 워커가 훑는다."
  def list_due_subscriptions(now \\ nil) do
    now = now || DateTime.utc_now(:second)

    Repo.all(
      from s in Subscription,
        where: s.state == "active" and s.current_period_end <= ^now,
        preload: [:plan_revision]
    )
  end

  @doc "계정의 요금 상태 한 묶음. 화면에 그대로 쓴다."
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
