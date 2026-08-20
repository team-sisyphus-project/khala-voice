defmodule VR.BillingTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Billing
  alias VR.Billing.{Credits, PlanRevision, Subscription}

  defp free_plan(included_credits \\ 500) do
    {:ok, plan} =
      Billing.create_plan(%{
        key: "free",
        display_name: "무료",
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

  describe "플랜 · 리비전" do
    test "리비전을 발행하면 이전 것은 구매 불가가 된다" do
      {plan, first} = free_plan(100)
      {:ok, second} = Billing.publish_revision(plan, %{included_credits: 200})

      assert second.revision == 2
      assert second.purchasable

      reloaded_first = VR.Repo.get!(PlanRevision, first.id)
      refute reloaded_first.purchasable
    end

    test "현재 리비전은 구매 가능한 것이다" do
      {plan, _} = free_plan(100)
      {:ok, second} = Billing.publish_revision(plan, %{included_credits: 200})

      assert Billing.current_revision(Billing.get_plan(plan.id)).id == second.id
    end

    test "지급량은 included_credits 다" do
      {_plan, revision} = free_plan(300)
      assert PlanRevision.granted_credits(revision) == 300
    end

    test "가격 형태가 깨지면 거부한다" do
      {plan, _} = free_plan()

      assert {:error, changeset} =
               Billing.publish_revision(plan, %{prices: %{"KRW" => "공짜"}})

      assert errors_on(changeset).prices
    end
  end

  describe "구독" do
    setup do
      {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
      {plan, revision} = free_plan(500)
      %{plan: plan, revision: revision}
    end

    test "가입하면 무료 플랜에 자동 구독되고 크레딧을 받는다" do
      account = account_fixture()

      subscription = Billing.get_subscription(account.id)
      assert subscription
      assert subscription.state == "active"
      # 플랜이 크레딧을 기본으로 준다
      assert Credits.balance(account.id) == 500
    end

    test "지급된 크레딧은 기간 말에 만료된다" do
      account = account_fixture()
      subscription = Billing.get_subscription(account.id)

      [lot] = Credits.list_lots(account.id)
      assert DateTime.compare(lot.expires_at, subscription.current_period_end) == :eq
    end

    test "구독은 리비전을 핀 고정한다 (그랜드파더링)", %{plan: plan, revision: revision} do
      account = account_fixture()
      subscription = Billing.get_subscription(account.id)
      assert subscription.plan_revision_id == revision.id

      # 새 리비전을 발행해도 기존 구독은 자기 것을 본다
      {:ok, _new} = Billing.publish_revision(plan, %{included_credits: 9999})

      reloaded = Billing.get_subscription(account.id)
      assert reloaded.plan_revision_id == revision.id
      assert reloaded.plan_revision.included_credits == 500
    end

    test "계정당 활성 구독은 하나뿐이다", %{revision: revision} do
      account = account_fixture()
      assert {:error, _} = Billing.subscribe(account.id, revision)
    end

    test "무료 플랜이 없어도 가입은 성립한다" do
      VR.Repo.delete_all(Subscription)
      VR.Repo.delete_all(PlanRevision)
      VR.Repo.delete_all(VR.Billing.Plan)

      account = account_fixture()
      assert account.id
      refute Billing.get_subscription(account.id)
    end
  end

  describe "기간 갱신" do
    setup do
      {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
      {_plan, _revision} = free_plan(500)
      %{account: account_fixture()}
    end

    test "기간이 끝나면 넘어가고 크레딧을 다시 받는다", %{account: account} do
      subscription = Billing.get_subscription(account.id)
      old_end = subscription.current_period_end

      {:ok, advanced} = Billing.advance_period(subscription)

      assert DateTime.compare(advanced.current_period_start, old_end) == :eq
      assert DateTime.compare(advanced.current_period_end, old_end) == :gt
      # 새 기간 크레딧이 더해진다
      assert Credits.balance(account.id) == 1000
    end

    test "같은 기간에 두 번 지급되지 않는다", %{account: account} do
      subscription = Billing.get_subscription(account.id)

      # 같은 기간에 다시 지급을 시도한다
      {:ok, :already_granted} =
        Billing.grant_period_credits(subscription, subscription.plan_revision)

      assert Credits.balance(account.id) == 500
    end

    test "기간이 끝난 구독만 갱신 대상이다", %{account: account} do
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

  describe "요약" do
    test "화면에 필요한 것을 한 묶음으로 준다" do
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

  describe "사용량 계량 idempotency" do
    setup do
      {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
      %{account: account_fixture()}
    end

    test "잔액이 있을 때 같은 열쇠로 두 번 계량하지 않는다", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 1000, source: "admin_grant", reason: "테스트")

      opts = [charge_domain: "llm", idempotency_key: "llm:meet_1:model", reason: "요약"]

      {:ok, first} = Credits.charge_usage(account.id, Decimal.new("0.15"), opts)
      {:ok, second} = Credits.charge_usage(account.id, Decimal.new("0.15"), opts)

      assert first.charged_credits > 0
      assert second[:already_charged]
      assert second.charged_credits == 0
      assert Credits.balance(account.id) == 1000 - first.charged_credits
    end

    test "잔액이 없어 오버드래프트로 가도 두 번 계량하지 않는다", %{account: account} do
      # 무료 플랜 + 어드민 키 구성에서는 잔액 0 이 기본 상태라 이 경로가 정상 경로다.
      # 부족분을 기록할 때마다 새 묶음이 생기므로, 열쇠를 묶음 id 로 파생시키면
      # 유니크 제약이 영영 걸리지 않고 재시도마다 다시 차감된다.
      opts = [charge_domain: "llm", idempotency_key: "llm:meet_2:model", reason: "요약"]

      {:ok, first} = Credits.charge_usage(account.id, Decimal.new("0.15"), opts)
      {:ok, second} = Credits.charge_usage(account.id, Decimal.new("0.15"), opts)

      assert first.charged_credits > 0
      assert second[:already_charged]
      assert Credits.balance(account.id) == -first.charged_credits
    end

    test "열쇠가 다르면 각각 계량한다", %{account: account} do
      base = [charge_domain: "llm", reason: "요약"]

      {:ok, a} =
        Credits.charge_usage(account.id, Decimal.new("0.15"), base ++ [idempotency_key: "llm:a"])

      {:ok, b} =
        Credits.charge_usage(account.id, Decimal.new("0.15"), base ++ [idempotency_key: "llm:b"])

      refute b[:already_charged]
      assert Credits.balance(account.id) == -(a.charged_credits + b.charged_credits)
    end

    test "원장 합계와 묶음 잔량 합계가 어긋나지 않는다", %{account: account} do
      # Σ delta == Σ lot.remaining 불변식. 오버드래프트가 이것을 지키려고 음수 묶음을 만든다.
      {:ok, _} = Credits.grant(account.id, 10, source: "admin_grant", reason: "적은 잔액")

      {:ok, _} =
        Credits.charge_usage(account.id, Decimal.new("0.15"),
          charge_domain: "llm",
          idempotency_key: "llm:meet_3:model"
        )

      assert Credits.ledger_total(account.id) == Credits.balance(account.id)
    end
  end
end
