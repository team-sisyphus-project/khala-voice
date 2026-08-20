defmodule VR.Billing.CreditsTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Billing.Credits

  setup do
    {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
    %{account: account_fixture()}
  end

  describe "지급" do
    test "잔액이 늘고 원장과 일치한다", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 100)

      assert Credits.balance(account.id) == 100
      assert Credits.ledger_total(account.id) == 100
    end

    test "같은 idempotency_key 로는 두 번 지급되지 않는다", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 100, idempotency_key: "same")
      assert {:error, :already_granted} = Credits.grant(account.id, 100, idempotency_key: "same")

      assert Credits.balance(account.id) == 100
    end
  end

  describe "소비 — FIFO" do
    test "만료 임박 묶음을 먼저 쓴다", %{account: account} do
      soon = DateTime.add(DateTime.utc_now(:second), 1, :day)
      later = DateTime.add(DateTime.utc_now(:second), 30, :day)

      {:ok, _} = Credits.grant(account.id, 50, expires_at: later)
      {:ok, _} = Credits.grant(account.id, 50, expires_at: soon)
      # 만료 없는 것
      {:ok, _} = Credits.grant(account.id, 50)

      {:ok, 60} = Credits.consume(account.id, 60)

      # list_lots 는 소비 순서(만료 임박 → 무기한)로 정렬하고 다 쓴 묶음은 빼고 준다
      lots = Credits.list_lots(account.id)

      assert Credits.balance(account.id) == 90

      # 곧 만료되는 50 이 전부 소진돼 목록에서 사라졌다
      assert length(lots) == 2

      # 남은 것은 30일짜리(50-10=40) 와 무기한(50)
      [expiring, forever] = lots
      assert expiring.remaining == 40
      assert forever.expires_at == nil
      assert forever.remaining == 50
    end

    test "만료 없는 묶음이 가장 나중에 쓰인다", %{account: account} do
      expiring = DateTime.add(DateTime.utc_now(:second), 5, :day)

      {:ok, _} = Credits.grant(account.id, 30)
      {:ok, _} = Credits.grant(account.id, 30, expires_at: expiring)

      {:ok, 30} = Credits.consume(account.id, 30)

      # 만료 있는 쪽이 비고 무기한이 남는다
      remaining = Credits.list_lots(account.id)
      assert [%{expires_at: nil, remaining: 30}] = remaining
    end

    test "잔액이 모자라면 거부하고 아무것도 바꾸지 않는다", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 10)

      assert {:error, :insufficient_credits} = Credits.consume(account.id, 50)
      assert Credits.balance(account.id) == 10
      assert Credits.ledger_total(account.id) == 10
    end

    test "여러 묶음에 걸쳐 소비해도 불변식이 유지된다", %{account: account} do
      for _ <- 1..5, do: Credits.grant(account.id, 20)

      {:ok, 75} = Credits.consume(account.id, 75)

      assert Credits.balance(account.id) == 25
      assert Credits.ledger_total(account.id) == 25
    end
  end

  describe "오버드래프트" do
    test "잔액이 음수가 될 수 있다", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 10)

      {:ok, 50} = Credits.consume_allow_overdraft(account.id, 50)

      assert Credits.balance(account.id) == -40
      # 불변식: 잔액 = 원장 합
      assert Credits.ledger_total(account.id) == -40
    end

    test "잔액이 0이어도 계량된다", %{account: account} do
      {:ok, 30} = Credits.consume_allow_overdraft(account.id, 30)

      assert Credits.balance(account.id) == -30
      assert Credits.ledger_total(account.id) == -30
    end
  end

  describe "회수 — 잔액을 음수로 만들지 않는다" do
    test "있는 만큼만 회수한다", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 30)

      {:ok, 30} = Credits.revoke(account.id, 100)

      assert Credits.balance(account.id) == 0
      assert Credits.ledger_total(account.id) == 0
    end
  end

  describe "만료" do
    test "만료된 묶음은 잔액에서 빠지고 원장에 기록된다", %{account: account} do
      past = DateTime.add(DateTime.utc_now(:second), -1, :day)
      {:ok, lot} = Credits.grant(account.id, 40, expires_at: past)

      # 잔액 조회는 이미 만료를 거른다
      assert Credits.balance(account.id) == 0

      assert Credits.expire_due_lots() == 1

      reloaded = VR.Repo.get!(VR.Billing.CreditLot, lot.id)
      assert reloaded.remaining == 0
      assert reloaded.expired_at
      # 만료 기록이 남아 불변식이 유지된다
      assert Credits.ledger_total(account.id) == 0
    end

    test "잔량이 0이면 원장을 더럽히지 않는다", %{account: account} do
      past = DateTime.add(DateTime.utc_now(:second), -1, :day)
      {:ok, _} = Credits.grant(account.id, 10, expires_at: past)

      before = length(Credits.list_ledger(account.id))
      Credits.expire_due_lots()
      # 지급 1 + 만료 1
      assert length(Credits.list_ledger(account.id)) == before + 1
    end
  end

  describe "환산 (devkanban 방식)" do
    test "usage_cost / credit_value 를 올림한다" do
      # 1 크레딧 = $0.0015, 사용 $0.016 → 10.67 → 올림 11
      {:ok, result} = Credits.convert_usage_cost(Decimal.new("0.016"))

      assert Decimal.equal?(result.credit_value_usd, Decimal.new("0.0015"))
      assert result.rounding_policy == "ceil"
      assert result.charged_credits == 11
    end

    test "딱 떨어지면 올림하지 않는다" do
      {:ok, result} = Credits.convert_usage_cost(Decimal.new("0.0030"))
      assert result.charged_credits == 2
    end

    test "아주 작은 사용도 1 크레딧이 된다 (올림)" do
      {:ok, result} = Credits.convert_usage_cost(Decimal.new("0.0001"))
      assert result.charged_credits == 1
    end

    test "환산 정책이 없으면 거부한다" do
      VR.Repo.delete_all(VR.Billing.CreditConversionSetting)
      assert {:error, :no_conversion_setting} = Credits.convert_usage_cost(Decimal.new("1"))
    end
  end

  describe "사용 계량" do
    test "원가를 크레딧으로 바꿔 차감하고 근거를 남긴다", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 100)

      {:ok, result} =
        Credits.charge_usage(account.id, Decimal.new("0.016"),
          charge_domain: "stt",
          reason: "전사 10분"
        )

      assert result.charged_credits == 11
      assert Credits.balance(account.id) == 89

      [entry | _] = Credits.list_ledger(account.id)
      assert entry.source == "usage"
      assert entry.charge_domain == "stt"
      assert Decimal.equal?(entry.usage_cost_usd, Decimal.new("0.016"))
      assert entry.charged_credits == 11
      assert entry.rounding_policy == "ceil"
    end

    test "0원이면 원장을 더럽히지 않는다", %{account: account} do
      {:ok, result} = Credits.charge_usage(account.id, Decimal.new("0"), charge_domain: "llm")

      assert result.charged_credits == 0
      assert Credits.list_ledger(account.id) == []
    end

    test "잔액이 없어도 계량된다 (사후 과금)", %{account: account} do
      {:ok, result} =
        Credits.charge_usage(account.id, Decimal.new("0.016"), charge_domain: "stt")

      assert result.charged_credits == 11
      assert Credits.balance(account.id) == -11
    end

    test "여러 묶음에 걸쳐도 idempotency_key 가 충돌하지 않는다", %{account: account} do
      for _ <- 1..3, do: Credits.grant(account.id, 4)

      # 11 크레딧이 4+4+3 으로 세 묶음에 걸린다
      {:ok, result} =
        Credits.charge_usage(account.id, Decimal.new("0.016"),
          charge_domain: "stt",
          idempotency_key: "session-abc"
        )

      assert result.charged_credits == 11
      assert Credits.balance(account.id) == 1
      assert Credits.ledger_total(account.id) == 1
    end
  end
end
