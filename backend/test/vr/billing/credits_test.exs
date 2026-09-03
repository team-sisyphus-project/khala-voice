defmodule VR.Billing.CreditsTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Billing.Credits

  setup do
    {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
    %{account: account_fixture()}
  end

  describe "granting" do
    test "balance increases and matches the ledger", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 100)

      assert Credits.balance(account.id) == 100
      assert Credits.ledger_total(account.id) == 100
    end

    test "the same idempotency_key does not grant twice", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 100, idempotency_key: "same")
      assert {:error, :already_granted} = Credits.grant(account.id, 100, idempotency_key: "same")

      assert Credits.balance(account.id) == 100
    end
  end

  describe "consumption — FIFO" do
    test "lots closest to expiry are spent first", %{account: account} do
      soon = DateTime.add(DateTime.utc_now(:second), 1, :day)
      later = DateTime.add(DateTime.utc_now(:second), 30, :day)

      {:ok, _} = Credits.grant(account.id, 50, expires_at: later)
      {:ok, _} = Credits.grant(account.id, 50, expires_at: soon)
      # One with no expiry
      {:ok, _} = Credits.grant(account.id, 50)

      {:ok, 60} = Credits.consume(account.id, 60)

      # list_lots sorts in consumption order (closest expiry → no expiry) and omits spent lots
      lots = Credits.list_lots(account.id)

      assert Credits.balance(account.id) == 90

      # The soon-to-expire 50 is fully spent and gone from the list
      assert length(lots) == 2

      # Remaining: the 30-day lot (50-10=40) and the no-expiry lot (50)
      [expiring, forever] = lots
      assert expiring.remaining == 40
      assert forever.expires_at == nil
      assert forever.remaining == 50
    end

    test "no-expiry lots are spent last", %{account: account} do
      expiring = DateTime.add(DateTime.utc_now(:second), 5, :day)

      {:ok, _} = Credits.grant(account.id, 30)
      {:ok, _} = Credits.grant(account.id, 30, expires_at: expiring)

      {:ok, 30} = Credits.consume(account.id, 30)

      # The expiring lot empties; the no-expiry one remains
      remaining = Credits.list_lots(account.id)
      assert [%{expires_at: nil, remaining: 30}] = remaining
    end

    test "insufficient balance rejects and changes nothing", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 10)

      assert {:error, :insufficient_credits} = Credits.consume(account.id, 50)
      assert Credits.balance(account.id) == 10
      assert Credits.ledger_total(account.id) == 10
    end

    test "the invariant holds even when consumption spans lots", %{account: account} do
      for _ <- 1..5, do: Credits.grant(account.id, 20)

      {:ok, 75} = Credits.consume(account.id, 75)

      assert Credits.balance(account.id) == 25
      assert Credits.ledger_total(account.id) == 25
    end
  end

  describe "overdraft" do
    test "the balance can go negative", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 10)

      {:ok, 50} = Credits.consume_allow_overdraft(account.id, 50)

      assert Credits.balance(account.id) == -40
      # Invariant: balance = ledger sum
      assert Credits.ledger_total(account.id) == -40
    end

    test "metered even at zero balance", %{account: account} do
      {:ok, 30} = Credits.consume_allow_overdraft(account.id, 30)

      assert Credits.balance(account.id) == -30
      assert Credits.ledger_total(account.id) == -30
    end
  end

  describe "revocation — never drives the balance negative" do
    test "revokes only what exists", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 30)

      {:ok, 30} = Credits.revoke(account.id, 100)

      assert Credits.balance(account.id) == 0
      assert Credits.ledger_total(account.id) == 0
    end
  end

  describe "expiry" do
    test "expired lots leave the balance and are recorded in the ledger", %{account: account} do
      past = DateTime.add(DateTime.utc_now(:second), -1, :day)
      {:ok, lot} = Credits.grant(account.id, 40, expires_at: past)

      # Balance queries already filter out expired lots
      assert Credits.balance(account.id) == 0

      assert Credits.expire_due_lots() == 1

      reloaded = VR.Repo.get!(VR.Billing.CreditLot, lot.id)
      assert reloaded.remaining == 0
      assert reloaded.expired_at
      # The expiry record keeps the invariant intact
      assert Credits.ledger_total(account.id) == 0
    end

    test "zero remainder does not pollute the ledger", %{account: account} do
      past = DateTime.add(DateTime.utc_now(:second), -1, :day)
      {:ok, _} = Credits.grant(account.id, 10, expires_at: past)

      before = length(Credits.list_ledger(account.id))
      Credits.expire_due_lots()
      # 1 grant + 1 expiry
      assert length(Credits.list_ledger(account.id)) == before + 1
    end
  end

  describe "conversion (devkanban style)" do
    test "rounds usage_cost / credit_value up" do
      # 1 credit = $0.0015, usage $0.016 → 10.67 → rounds up to 11
      {:ok, result} = Credits.convert_usage_cost(Decimal.new("0.016"))

      assert Decimal.equal?(result.credit_value_usd, Decimal.new("0.0015"))
      assert result.rounding_policy == "ceil"
      assert result.charged_credits == 11
    end

    test "no rounding when it divides evenly" do
      {:ok, result} = Credits.convert_usage_cost(Decimal.new("0.0030"))
      assert result.charged_credits == 2
    end

    test "even tiny usage becomes 1 credit (ceil)" do
      {:ok, result} = Credits.convert_usage_cost(Decimal.new("0.0001"))
      assert result.charged_credits == 1
    end

    test "rejects without a conversion setting" do
      VR.Repo.delete_all(VR.Billing.CreditConversionSetting)
      assert {:error, :no_conversion_setting} = Credits.convert_usage_cost(Decimal.new("1"))
    end
  end

  describe "usage metering" do
    test "converts cost to credits, deducts, and records evidence", %{account: account} do
      {:ok, _} = Credits.grant(account.id, 100)

      {:ok, result} =
        Credits.charge_usage(account.id, Decimal.new("0.016"),
          charge_domain: "stt",
          reason: "10 min transcription"
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

    test "zero cost does not pollute the ledger", %{account: account} do
      {:ok, result} = Credits.charge_usage(account.id, Decimal.new("0"), charge_domain: "llm")

      assert result.charged_credits == 0
      assert Credits.list_ledger(account.id) == []
    end

    test "metered even without balance (post-hoc billing)", %{account: account} do
      {:ok, result} =
        Credits.charge_usage(account.id, Decimal.new("0.016"), charge_domain: "stt")

      assert result.charged_credits == 11
      assert Credits.balance(account.id) == -11
    end

    test "idempotency_key does not collide across lots", %{account: account} do
      for _ <- 1..3, do: Credits.grant(account.id, 4)

      # 11 credits span three lots as 4+4+3
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
