defmodule VR.Billing.Credits do
  @moduledoc """
  크레딧 잔액 · 지급 · 소비.

  **출처: devkanban** `lib/manualsquad/billing/credits.ex`
  — 보류(hold) · 오토충전 · 워크스페이스 계량을 제거하고 FIFO 소비만 남겼다.

  ## 불변식

      잔액 = Σ ledger.delta = Σ lot.remaining

  잔액을 캐시하지 않는다. 캐시와 원장이 어긋나면 어느 쪽이 맞는지 알 수 없다.

  ## 소비 순서

  **만료 임박 순 → 만료 없는 것 → 삽입순.**
  사라질 크레딧을 먼저 써야 사용자가 손해를 보지 않는다.

  ## 동시성

  소비는 트랜잭션 안에서 `FOR UPDATE` 로 묶음을 잠근다.
  잠그지 않으면 동시 요청 둘이 같은 잔액을 보고 각각 차감해 이중 지출이 난다.
  """

  import Ecto.Query, warn: false

  alias VR.Billing.{CreditConversionSetting, CreditLedgerEntry, CreditLot}
  alias VR.Repo

  require Logger

  # ── 잔액 ─────────────────────────────────────────────────

  @doc """
  쓸 수 있는 잔액. 만료되지 않은 묶음의 `remaining` 합.

  오버드래프트로 **음수가 될 수 있다.**
  """
  def balance(account_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.one(
      from l in CreditLot,
        where:
          l.account_id == ^account_id and is_nil(l.expired_at) and
            (is_nil(l.expires_at) or l.expires_at > ^now),
        select: coalesce(sum(l.remaining), 0)
    ) || 0
  end

  @doc "원장 합계. 불변식 검증에 쓴다 — 잔액과 같아야 한다."
  def ledger_total(account_id) do
    Repo.one(
      from e in CreditLedgerEntry,
        where: e.account_id == ^account_id,
        select: coalesce(sum(e.delta), 0)
    ) || 0
  end

  @doc "만료 예정 묶음 목록. 사용자 화면에 '언제 사라지는지' 보여줄 때 쓴다."
  def list_lots(account_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.all(
      from l in CreditLot,
        where:
          l.account_id == ^account_id and is_nil(l.expired_at) and l.remaining != 0 and
            (is_nil(l.expires_at) or l.expires_at > ^now),
        order_by: [asc_nulls_last: l.expires_at, asc: l.inserted_at]
    )
  end

  @doc "사용 내역."
  def list_ledger(account_id, opts \\ []) do
    Repo.all(
      from e in CreditLedgerEntry,
        where: e.account_id == ^account_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^(opts[:limit] || 50)
    )
  end

  # ── 지급 ─────────────────────────────────────────────────

  @doc """
  크레딧을 지급한다.

  ## 옵션
  - `:source` — `plan_grant` | `admin_grant` (기본 `admin_grant`)
  - `:expires_at` — 없으면 무기한
  - `:reason` · `:actor_id` — 감사용
  - `:idempotency_key` — 같은 지급을 두 번 하지 않기 위한 열쇠
  """
  def grant(account_id, amount, opts \\ []) when is_integer(amount) and amount > 0 do
    source = opts[:source] || "admin_grant"

    Repo.transaction(fn ->
      lot =
        %CreditLot{}
        |> CreditLot.changeset(%{
          account_id: account_id,
          source: source,
          amount: amount,
          remaining: amount,
          expires_at: opts[:expires_at],
          origin: opts[:origin] || %{}
        })
        |> Repo.insert!()

      entry_attrs = %{
        account_id: account_id,
        credit_lot_id: lot.id,
        delta: amount,
        source: source,
        reason: opts[:reason],
        actor_id: opts[:actor_id],
        idempotency_key: opts[:idempotency_key]
      }

      case %CreditLedgerEntry{} |> CreditLedgerEntry.changeset(entry_attrs) |> Repo.insert() do
        {:ok, _entry} ->
          lot

        {:error, %{errors: errors}} ->
          # idempotency_key 충돌 = 이미 지급된 것. 롤백해 중복 지급을 막는다.
          if Keyword.has_key?(errors, :idempotency_key) do
            Repo.rollback(:already_granted)
          else
            Repo.rollback(:grant_failed)
          end
      end
    end)
  end

  @doc """
  관리자 회수. **잔액을 음수로 만들 수 없다** — 있는 만큼만 회수한다.

  devkanban 확정 결정 §2-6.
  """
  def revoke(account_id, amount, opts \\ []) when is_integer(amount) and amount > 0 do
    Repo.transaction(fn ->
      lots = lock_available_lots(account_id)
      available = Enum.reduce(lots, 0, &(CreditLot.spendable(&1) + &2))
      to_take = min(amount, available)

      if to_take > 0 do
        take_from_lots(lots, to_take, account_id, "admin_revoke", opts)
      end

      to_take
    end)
  end

  # ── 소비 ─────────────────────────────────────────────────

  @doc """
  크레딧을 쓴다. **잔액이 모자라면 거부한다.**

  선불 성격의 작업(아직 시작하지 않은 것)에 쓴다.
  """
  def consume(account_id, amount, opts \\ []) when is_integer(amount) and amount > 0 do
    Repo.transaction(fn ->
      lots = lock_available_lots(account_id)
      available = Enum.reduce(lots, 0, &(CreditLot.spendable(&1) + &2))

      if available < amount do
        Repo.rollback(:insufficient_credits)
      else
        take_from_lots(lots, amount, account_id, opts[:source] || "adjustment", opts)
        amount
      end
    end)
  end

  @doc """
  크레딧을 쓰되 **잔액이 음수가 되는 것을 허용한다.**

  전사·요약처럼 **작업이 이미 끝난 뒤에 계량되는** 것에 쓴다.
  이미 비용이 발생했으므로 막을 수 없고, 막으면 원장만 틀어진다.

  부족분은 `remaining` 이 음수인 오버드래프트 묶음으로 기록한다 —
  그래야 `Σ delta == Σ remaining` 이 유지된다.
  """
  def consume_allow_overdraft(account_id, amount, opts \\ [])
      when is_integer(amount) and amount > 0 do
    # 기본은 adjustment 다. "usage" 는 원가 근거를 요구하므로
    # `charge_usage/3` 가 근거를 채워 넣을 때만 쓴다.
    source = opts[:source] || "adjustment"

    Repo.transaction(fn ->
      lots = lock_available_lots(account_id)
      available = Enum.reduce(lots, 0, &(CreditLot.spendable(&1) + &2))
      from_lots = min(available, amount)
      shortfall = amount - from_lots

      if from_lots > 0 do
        take_from_lots(lots, from_lots, account_id, source, opts)
      end

      if shortfall > 0 do
        record_overdraft(account_id, shortfall, source, opts)
      end

      amount
    end)
  end

  # ── 만료 ─────────────────────────────────────────────────

  @doc """
  만료된 묶음을 정리한다. 남은 잔량만큼 음수 원장을 남겨 불변식을 지킨다.

  잔량이 0 이면 원장을 만들지 않는다 — 아무 일도 없었기 때문이다.
  """
  def expire_due_lots(now \\ nil) do
    now = now || DateTime.utc_now(:microsecond)

    due =
      Repo.all(
        from l in CreditLot,
          where: not is_nil(l.expires_at) and l.expires_at <= ^now and is_nil(l.expired_at)
      )

    Enum.reduce(due, 0, fn lot, count ->
      Repo.transaction(fn ->
        if lot.remaining > 0 do
          Repo.insert!(
            CreditLedgerEntry.changeset(%CreditLedgerEntry{}, %{
              account_id: lot.account_id,
              credit_lot_id: lot.id,
              delta: -lot.remaining,
              source: "expiry",
              reason: "기간 만료"
            })
          )
        end

        Repo.update_all(
          from(l in CreditLot, where: l.id == ^lot.id),
          set: [remaining: 0, expired_at: now]
        )
      end)

      count + 1
    end)
  end

  # ── 환산 ─────────────────────────────────────────────────

  @doc "현재 환산 정책. 없으면 nil — 그러면 사용량을 크레딧으로 바꿀 수 없다."
  def conversion_setting do
    Repo.one(
      from s in CreditConversionSetting,
        where: s.singleton_key == ^CreditConversionSetting.singleton_key()
    )
  end

  @doc "환산 정책을 저장한다. 싱글턴이라 항상 같은 행을 고친다."
  def put_conversion_setting(attrs, actor_id \\ nil) do
    setting = conversion_setting() || %CreditConversionSetting{}
    attrs = Map.put(attrs, :updated_by_id, actor_id)

    setting |> CreditConversionSetting.changeset(attrs) |> Repo.insert_or_update()
  end

  @doc """
  사용 원가(USD)를 크레딧으로 바꾼다.

  **출처: devkanban** `credit_conversions.ex` `convert_usage_cost/2`.

      computed_credits = usage_cost_usd / credit_value_usd
      charged_credits  = ceil(computed_credits)
  """
  def convert_usage_cost(usage_cost_usd, setting \\ nil)

  def convert_usage_cost(usage_cost_usd, nil) do
    case conversion_setting() do
      nil -> {:error, :no_conversion_setting}
      setting -> convert_usage_cost(usage_cost_usd, setting)
    end
  end

  def convert_usage_cost(usage_cost_usd, %CreditConversionSetting{} = setting) do
    cost = to_decimal(usage_cost_usd)
    computed = Decimal.div(cost, setting.credit_value_usd)

    {:ok,
     %{
       usage_cost_usd: cost,
       credit_value_usd: setting.credit_value_usd,
       rounding_policy: setting.rounding_policy,
       computed_credits: computed,
       charged_credits: apply_rounding(computed, setting.rounding_policy)
     }}
  end

  @doc "환산 규칙에 따라 정수로 만든다."
  def apply_rounding(%Decimal{} = credits, "floor"),
    do: credits |> Decimal.round(0, :floor) |> Decimal.to_integer()

  def apply_rounding(%Decimal{} = credits, "round"),
    do: credits |> Decimal.round(0, :half_up) |> Decimal.to_integer()

  def apply_rounding(%Decimal{} = credits, _ceil),
    do: credits |> Decimal.round(0, :ceiling) |> Decimal.to_integer()

  @doc """
  사용량을 계량해 크레딧을 차감한다. 전사·요약 워커가 부른다.

  ## 옵션
  - `:charge_domain` — `"stt"` | `"llm"` (필수)
  - `:idempotency_key` — 재시도로 두 번 기록되는 것을 막는다
  - `:pricing_snapshot` — 나중에 재계산할 수 있게 남기는 근거
  """
  def charge_usage(account_id, usage_cost_usd, opts \\ []) do
    with {:ok, conversion} <- convert_usage_cost(usage_cost_usd) do
      if conversion.charged_credits <= 0 do
        # 0원이거나 반올림해서 0이면 원장을 더럽히지 않는다
        {:ok, %{charged_credits: 0, conversion: conversion}}
      else
        opts =
          opts
          |> Keyword.put(:source, "usage")
          |> Keyword.put(:usage_cost_usd, conversion.usage_cost_usd)
          |> Keyword.put(:credit_value_usd, conversion.credit_value_usd)
          |> Keyword.put(:computed_credits, conversion.computed_credits)
          |> Keyword.put(:charged_credits, conversion.charged_credits)
          |> Keyword.put(:rounding_policy, conversion.rounding_policy)

        case consume_allow_overdraft(account_id, conversion.charged_credits, opts) do
          {:ok, _} ->
            {:ok, %{charged_credits: conversion.charged_credits, conversion: conversion}}

          # 같은 열쇠로 이미 계량된 건이다. 워커 재시도에서 정상적으로 일어난다.
          {:error, :already_charged} ->
            {:ok, %{charged_credits: 0, conversion: conversion, already_charged: true}}

          error ->
            error
        end
      end
    end
  end

  # ── 내부 ─────────────────────────────────────────────────

  # 만료 임박 순 → 만료 없는 것 → 삽입순. 트랜잭션 안에서 잠근다.
  defp lock_available_lots(account_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.all(
      from l in CreditLot,
        where:
          l.account_id == ^account_id and l.remaining > 0 and is_nil(l.expired_at) and
            (is_nil(l.expires_at) or l.expires_at > ^now),
        order_by: [asc_nulls_last: l.expires_at, asc: l.inserted_at, asc: l.id],
        lock: "FOR UPDATE"
    )
  end

  defp take_from_lots(_lots, 0, _account_id, _source, _opts), do: :ok

  defp take_from_lots([], remaining, _account_id, _source, _opts) when remaining > 0 do
    # 호출부가 미리 확인하므로 여기 오면 안 된다. 오면 깨끗하게 되돌린다.
    Repo.rollback(:insufficient_credits)
  end

  defp take_from_lots([lot | rest], remaining, account_id, source, opts) do
    take = min(CreditLot.spendable(lot), remaining)

    Repo.update_all(from(l in CreditLot, where: l.id == ^lot.id), inc: [remaining: -take])

    insert_entry!(account_id, lot.id, -take, source, opts)

    take_from_lots(rest, remaining - take, account_id, source, opts)
  end

  # 원장 항목을 넣는다.
  #
  # `idempotency_key` 충돌은 **오류가 아니라 "이미 처리됨"** 이다.
  # 워커가 재시도되면 같은 열쇠로 다시 들어오는데, 그때 예외를 던지면
  # 이미 끝난 일 때문에 잡이 실패로 남는다. 조용히 되돌린다.
  defp insert_entry!(account_id, lot_id, delta, source, opts) do
    attrs = ledger_attrs(account_id, lot_id, delta, source, opts)

    case %CreditLedgerEntry{} |> CreditLedgerEntry.changeset(attrs) |> Repo.insert() do
      {:ok, entry} ->
        entry

      {:error, %{errors: errors}} ->
        if Keyword.has_key?(errors, :idempotency_key) do
          Repo.rollback(:already_charged)
        else
          Repo.rollback({:ledger_insert_failed, errors})
        end
    end
  end

  # 잔액이 모자란 만큼을 음수 묶음으로 남긴다. Σ delta == Σ remaining 을 지키기 위함.
  defp record_overdraft(account_id, shortfall, source, opts) do
    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        account_id: account_id,
        source: "overdraft",
        amount: 0,
        remaining: -shortfall,
        origin: %{"reason" => "잔액 부족분"}
      })
      |> Repo.insert!()

    insert_entry!(
      account_id,
      lot.id,
      -shortfall,
      source,
      Keyword.put(opts, :key_part, :overdraft)
    )

    Logger.info("[Credits] 오버드래프트 #{shortfall} — account=#{account_id}")
  end

  defp ledger_attrs(account_id, lot_id, delta, source, opts) do
    %{
      account_id: account_id,
      credit_lot_id: lot_id,
      delta: delta,
      source: source,
      reason: opts[:reason],
      actor_id: opts[:actor_id],
      idempotency_key: scoped_key(opts[:idempotency_key], opts[:key_part] || {:lot, lot_id}),
      charge_domain: opts[:charge_domain],
      usage_cost_usd: opts[:usage_cost_usd],
      credit_value_usd: opts[:credit_value_usd],
      computed_credits: opts[:computed_credits],
      charged_credits: opts[:charged_credits],
      rounding_policy: opts[:rounding_policy],
      pricing_snapshot: opts[:pricing_snapshot]
    }
  end

  # 한 번의 사용이 여러 묶음에 걸치면 원장 항목도 여러 개가 된다.
  # 같은 열쇠를 그대로 쓰면 유니크 제약에 걸리므로 묶음별로 파생시킨다.
  # **출처: devkanban** `usage_idempotency_key/2`.
  #
  # 오버드래프트는 묶음 id 로 파생시키면 안 된다. 부족분을 기록할 때마다
  # **새 묶음이 생기므로** 열쇠가 매번 달라지고, 유니크 제약이 영영 걸리지 않는다.
  # 잔액이 0 이하인 계정(무료 플랜의 기본 상태다)에서 워커가 재시도되면
  # 같은 사용이 몇 번이고 다시 차감된다. devkanban 이 여기에 고정 접미사를 쓰는 이유다.
  defp scoped_key(nil, _part), do: nil
  defp scoped_key(key, {:lot, lot_id}), do: "#{key}:lot:#{lot_id}"
  defp scoped_key(key, :overdraft), do: "#{key}:overdraft"

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
