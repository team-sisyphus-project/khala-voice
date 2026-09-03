defmodule VR.Billing.Credits do
  @moduledoc """
  Credit balance, grants, and consumption.

  **Source: devkanban** `lib/manualsquad/billing/credits.ex`
  — removed holds, auto top-up, and workspace metering; only FIFO consumption remains.

  ## Invariant

      balance = Σ ledger.delta = Σ lot.remaining

  The balance is never cached. If a cache and the ledger disagree, there is no way
  to know which one is right.

  ## Consumption order

  **Soonest-expiring first → no expiry → insertion order.**
  Credits about to vanish must be spent first so users never lose out.

  ## Concurrency

  Consumption locks lots with `FOR UPDATE` inside a transaction.
  Without the lock, two concurrent requests would see the same balance and each
  deduct from it, causing double spending.
  """

  import Ecto.Query, warn: false

  alias VR.Billing.{CreditConversionSetting, CreditLedgerEntry, CreditLot}
  alias VR.Repo

  require Logger

  # ── Balance ──────────────────────────────────────────────

  @doc """
  The spendable balance: the sum of `remaining` across unexpired lots.

  **Can be negative** due to overdraft.
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

  @doc "Ledger total. Used to verify the invariant — must equal the balance."
  def ledger_total(account_id) do
    Repo.one(
      from e in CreditLedgerEntry,
        where: e.account_id == ^account_id,
        select: coalesce(sum(e.delta), 0)
    ) || 0
  end

  @doc "Lots pending expiry. Used on the user-facing screen to show when credits will disappear."
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

  @doc "Usage history."
  def list_ledger(account_id, opts \\ []) do
    Repo.all(
      from e in CreditLedgerEntry,
        where: e.account_id == ^account_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^(opts[:limit] || 50)
    )
  end

  # ── Grants ───────────────────────────────────────────────

  @doc """
  Grants credits.

  ## Options
  - `:source` — `plan_grant` | `admin_grant` (default `admin_grant`)
  - `:expires_at` — indefinite when absent
  - `:reason` and `:actor_id` — for auditing
  - `:idempotency_key` — key that prevents the same grant from happening twice
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
          # An idempotency_key conflict means it was already granted. Roll back to prevent a duplicate grant.
          if Keyword.has_key?(errors, :idempotency_key) do
            Repo.rollback(:already_granted)
          else
            Repo.rollback(:grant_failed)
          end
      end
    end)
  end

  @doc """
  Admin revocation. **Cannot drive the balance negative** — only takes what is there.

  devkanban confirmed decision §2-6.
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

  # ── Consumption ──────────────────────────────────────────

  @doc """
  Consumes credits. **Refuses when the balance is insufficient.**

  Use for prepaid-style operations (work that has not started yet).
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
  Consumes credits but **allows the balance to go negative.**

  Use for work that is **metered only after it has already finished**, like
  transcription and summary. The cost has already been incurred, so it cannot be
  blocked — blocking would only corrupt the ledger.

  The shortfall is recorded as an overdraft lot with a negative `remaining` —
  that keeps `Σ delta == Σ remaining`.
  """
  def consume_allow_overdraft(account_id, amount, opts \\ [])
      when is_integer(amount) and amount > 0 do
    # Defaults to adjustment. "usage" requires cost evidence, so it is only
    # used when `charge_usage/3` fills that evidence in.
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

  # ── Expiry ───────────────────────────────────────────────

  @doc """
  Cleans up expired lots. Writes a negative ledger entry for the remaining amount
  to preserve the invariant.

  No ledger entry is created when the remaining amount is 0 — nothing happened.
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
              reason: "Period expired"
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

  # ── Conversion ───────────────────────────────────────────

  @doc "The current conversion policy. nil when absent — usage then cannot be converted to credits."
  def conversion_setting do
    Repo.one(
      from s in CreditConversionSetting,
        where: s.singleton_key == ^CreditConversionSetting.singleton_key()
    )
  end

  @doc "Saves the conversion policy. It is a singleton, so the same row is always updated."
  def put_conversion_setting(attrs, actor_id \\ nil) do
    setting = conversion_setting() || %CreditConversionSetting{}
    attrs = Map.put(attrs, :updated_by_id, actor_id)

    setting |> CreditConversionSetting.changeset(attrs) |> Repo.insert_or_update()
  end

  @doc """
  Converts usage cost (USD) into credits.

  **Source: devkanban** `credit_conversions.ex` `convert_usage_cost/2`.

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

  @doc "Rounds to an integer according to the conversion rule."
  def apply_rounding(%Decimal{} = credits, "floor"),
    do: credits |> Decimal.round(0, :floor) |> Decimal.to_integer()

  def apply_rounding(%Decimal{} = credits, "round"),
    do: credits |> Decimal.round(0, :half_up) |> Decimal.to_integer()

  def apply_rounding(%Decimal{} = credits, _ceil),
    do: credits |> Decimal.round(0, :ceiling) |> Decimal.to_integer()

  @doc """
  Meters usage and deducts credits. Called by the transcription and summary workers.

  ## Options
  - `:charge_domain` — `"stt"` | `"llm"` (required)
  - `:idempotency_key` — prevents double recording on retries
  - `:pricing_snapshot` — evidence kept so the charge can be recomputed later
  """
  def charge_usage(account_id, usage_cost_usd, opts \\ []) do
    with {:ok, conversion} <- convert_usage_cost(usage_cost_usd) do
      if conversion.charged_credits <= 0 do
        # Don't pollute the ledger when the cost is zero or rounds to zero
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

          # Already metered under the same key. Happens normally on worker retries.
          {:error, :already_charged} ->
            {:ok, %{charged_credits: 0, conversion: conversion, already_charged: true}}

          error ->
            error
        end
      end
    end
  end

  # ── Internal ─────────────────────────────────────────────

  # Soonest-expiring first → no expiry → insertion order. Locked inside the transaction.
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
    # Callers check beforehand, so this should never be reached. If it is, roll back cleanly.
    Repo.rollback(:insufficient_credits)
  end

  defp take_from_lots([lot | rest], remaining, account_id, source, opts) do
    take = min(CreditLot.spendable(lot), remaining)

    Repo.update_all(from(l in CreditLot, where: l.id == ^lot.id), inc: [remaining: -take])

    insert_entry!(account_id, lot.id, -take, source, opts)

    take_from_lots(rest, remaining - take, account_id, source, opts)
  end

  # Inserts a ledger entry.
  #
  # An `idempotency_key` conflict is **"already processed", not an error.**
  # A retried worker comes back in with the same key; throwing an exception then
  # would leave the job marked failed over work that already finished. Roll back quietly.
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

  # Records the shortfall as a negative lot. Preserves Σ delta == Σ remaining.
  defp record_overdraft(account_id, shortfall, source, opts) do
    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        account_id: account_id,
        source: "overdraft",
        amount: 0,
        remaining: -shortfall,
        origin: %{"reason" => "balance shortfall"}
      })
      |> Repo.insert!()

    insert_entry!(
      account_id,
      lot.id,
      -shortfall,
      source,
      Keyword.put(opts, :key_part, :overdraft)
    )

    Logger.info("[Credits] overdraft #{shortfall} — account=#{account_id}")
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

  # One usage spanning multiple lots produces multiple ledger entries.
  # Reusing the same key verbatim would trip the unique constraint, so it is
  # derived per lot.
  # **Source: devkanban** `usage_idempotency_key/2`.
  #
  # Overdraft must NOT be derived from the lot id. Each recorded shortfall
  # **creates a new lot**, so the key would differ every time and the unique
  # constraint would never fire. On an account with a balance at or below zero
  # (the default state on the free plan), a retried worker would deduct the same
  # usage over and over. That is why devkanban uses a fixed suffix here.
  defp scoped_key(nil, _part), do: nil
  defp scoped_key(key, {:lot, lot_id}), do: "#{key}:lot:#{lot_id}"
  defp scoped_key(key, :overdraft), do: "#{key}:overdraft"

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
