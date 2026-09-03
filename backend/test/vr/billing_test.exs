defmodule VR.BillingTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Billing
  alias VR.Billing.{Credits, PlanRevision, Subscription}

  defp free_plan(included_credits \\ 500) do
    {:ok, plan} =
      Billing.create_plan(%{
        key: "free",
        display_name: "Free",
        status: "published",
        publicly_listed: true
      })

    {:ok, revision} =
      Billing.publish_revision(plan, %{
        prices: %{"KRW" => %{"amount" => 0}},
        interval: "month",
        included_credits: included_credits
      })

    {plan, revision}
  end

  describe "plans and revisions" do
    test "publishing a revision makes the previous one unpurchasable" do
      {plan, first} = free_plan(100)
      {:ok, second} = Billing.publish_revision(plan, %{included_credits: 200})

      assert second.revision == 2
      assert second.purchasable

      reloaded_first = VR.Repo.get!(PlanRevision, first.id)
      refute reloaded_first.purchasable
    end

    test "the current revision is the purchasable one" do
      {plan, _} = free_plan(100)
      {:ok, second} = Billing.publish_revision(plan, %{included_credits: 200})

      assert Billing.current_revision(Billing.get_plan(plan.id)).id == second.id
    end

    test "the grant amount is included_credits" do
      {_plan, revision} = free_plan(300)
      assert PlanRevision.granted_credits(revision) == 300
    end

    test "rejects a malformed price shape" do
      {plan, _} = free_plan()

      assert {:error, changeset} =
               Billing.publish_revision(plan, %{prices: %{"KRW" => "free"}})

      assert errors_on(changeset).prices
    end
  end

  describe "subscriptions" do
    setup do
      {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
      {plan, revision} = free_plan(500)
      %{plan: plan, revision: revision}
    end

    test "signup auto-subscribes to the free plan and grants credits" do
      account = account_fixture()

      subscription = Billing.get_subscription(account.id)
      assert subscription
      assert subscription.state == "active"
      # The plan grants credits by default
      assert Credits.balance(account.id) == 500
    end

    test "granted credits expire at period end" do
      account = account_fixture()
      subscription = Billing.get_subscription(account.id)

      [lot] = Credits.list_lots(account.id)
      assert DateTime.compare(lot.expires_at, subscription.current_period_end) == :eq
    end

    test "subscriptions pin their revision (grandfathering)", %{plan: plan, revision: revision} do
      account = account_fixture()
      subscription = Billing.get_subscription(account.id)
      assert subscription.plan_revision_id == revision.id

      # Even after a new revision is published, existing subscriptions see their own
      {:ok, _new} = Billing.publish_revision(plan, %{included_credits: 9999})

      reloaded = Billing.get_subscription(account.id)
      assert reloaded.plan_revision_id == revision.id
      assert reloaded.plan_revision.included_credits == 500
    end

    test "only one active subscription per account", %{revision: revision} do
      account = account_fixture()
      assert {:error, _} = Billing.subscribe(account.id, revision)
    end

    test "signup still succeeds without a free plan" do
      VR.Repo.delete_all(Subscription)
      VR.Repo.delete_all(PlanRevision)
      VR.Repo.delete_all(VR.Billing.Plan)

      account = account_fixture()
      assert account.id
      refute Billing.get_subscription(account.id)
    end
  end

  describe "period renewal" do
    setup do
      {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
      {_plan, _revision} = free_plan(500)
      %{account: account_fixture()}
    end

    test "rolls over at period end and grants credits again", %{account: account} do
      subscription = Billing.get_subscription(account.id)
      old_end = subscription.current_period_end

      {:ok, advanced} = Billing.advance_period(subscription)

      assert DateTime.compare(advanced.current_period_start, old_end) == :eq
      assert DateTime.compare(advanced.current_period_end, old_end) == :gt
      # New-period credits are added
      assert Credits.balance(account.id) == 1000
    end

    test "not granted twice within the same period", %{account: account} do
      subscription = Billing.get_subscription(account.id)

      # Attempt to grant again within the same period
      {:ok, :already_granted} =
        Billing.grant_period_credits(subscription, subscription.plan_revision)

      assert Credits.balance(account.id) == 500
    end

    test "only subscriptions past period end are due for renewal", %{account: account} do
      assert Billing.list_due_subscriptions() == []

      subscription = Billing.get_subscription(account.id)
      past = DateTime.add(DateTime.utc_now(:second), -1, :day)

      subscription
      |> Ecto.Changeset.change(%{current_period_end: past})
      |> VR.Repo.update!()

      assert [due] = Billing.list_due_subscriptions()
      assert due.id == subscription.id
    end
  end

  describe "summary" do
    test "returns everything the screen needs in one bundle" do
      {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
      free_plan(500)
      account = account_fixture()

      summary = Billing.account_summary(account.id)

      assert summary.subscription
      assert summary.plan.key == "free"
      assert summary.revision.included_credits == 500
      assert summary.balance == 500
      assert length(summary.lots) == 1
    end
  end

  describe "usage metering idempotency" do
    setup do
      {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
      %{account: account_fixture()}
    end

    test "with a balance, the same key is not metered twice", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 1000, source: "admin_grant", reason: "test")

      opts = [charge_domain: "llm", idempotency_key: "llm:meet_1:model", reason: "summary"]

      {:ok, first} = Credits.charge_usage(account.id, Decimal.new("0.15"), opts)
      {:ok, second} = Credits.charge_usage(account.id, Decimal.new("0.15"), opts)

      assert first.charged_credits > 0
      assert second[:already_charged]
      assert second.charged_credits == 0
      assert Credits.balance(account.id) == 1000 - first.charged_credits
    end

    test "even overdrafting with no balance, not metered twice", %{account: account} do
      # With a free plan + admin keys, zero balance is the default state, so this path is the normal path.
      # Recording the shortfall creates a new lot each time, so deriving the key from the
      # lot id would mean the unique constraint never fires and every retry charges again.
      opts = [charge_domain: "llm", idempotency_key: "llm:meet_2:model", reason: "summary"]

      {:ok, first} = Credits.charge_usage(account.id, Decimal.new("0.15"), opts)
      {:ok, second} = Credits.charge_usage(account.id, Decimal.new("0.15"), opts)

      assert first.charged_credits > 0
      assert second[:already_charged]
      assert Credits.balance(account.id) == -first.charged_credits
    end

    test "different keys are metered separately", %{account: account} do
      base = [charge_domain: "llm", reason: "summary"]

      {:ok, a} =
        Credits.charge_usage(account.id, Decimal.new("0.15"), base ++ [idempotency_key: "llm:a"])

      {:ok, b} =
        Credits.charge_usage(account.id, Decimal.new("0.15"), base ++ [idempotency_key: "llm:b"])

      refute b[:already_charged]
      assert Credits.balance(account.id) == -(a.charged_credits + b.charged_credits)
    end

    test "ledger total and lot remainders never diverge", %{account: account} do
      # The Σ delta == Σ lot.remaining invariant. Overdraft creates negative lots to preserve it.
      {:ok, _} = Credits.grant(account.id, 10, source: "admin_grant", reason: "small balance")

      {:ok, _} =
        Credits.charge_usage(account.id, Decimal.new("0.15"),
          charge_domain: "llm",
          idempotency_key: "llm:meet_3:model"
        )

      assert Credits.ledger_total(account.id) == Credits.balance(account.id)
    end
  end
end
