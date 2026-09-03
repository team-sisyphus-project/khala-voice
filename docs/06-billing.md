# 06. Subscriptions & Credits

> **Source: devkanban.** Every structure related to pricing policy comes from the
> `devkanban` repo. Design principles are in `docs/billing-commerce-design.md`; the
> implementation is `lib/manualsquad/billing/*`.
> What changed and how is laid out in [14-provenance.md](14-provenance.md).

For now there is only a free plan and no actual payments. Even so, **metering runs precisely.**

## Design principles (devkanban `billing-commerce-design.md` §2)

1. **Separate the catalog from the contract.** Product definitions (`Plan`) and the
   contract an account holds (`Subscription`) are distinct, and a subscription **pins** a
   specific `PlanRevision`. Changing a price issues a new revision while existing
   subscriptions keep their own (automatic grandfathering).
2. **The ledger is append-only.** Balances are never mutated directly; they are derived
   as the sum of change records.
3. **Payment-provider neutral.** Only `provider` + `external_id` columns exist;
   integration comes later.
4. Monthly plan grants expire at period end (no rollover). Admin grants are open-ended
   unless given an explicit expiry.
5. **Revocation can never drive a balance negative.**

---

## Catalog

### Plan — mutable metadata
> devkanban `lib/manualsquad/billing/plan.ex`

```elixir
key              # "free" — the key referenced from code
status           # draft | published | deprecated | retired
display_name, description, name_i18n, description_i18n
icon, sort_order, publicly_listed
```

Metadata edits **apply to everyone immediately**. No revision is created.

### PlanRevision — immutable commercial snapshot
> devkanban `lib/manualsquad/billing/plan_revision.ex`

```elixir
revision           :integer
prices             :map      # %{"KRW" => %{amount: 0}, "USD" => %{amount: 0}} (minor unit)
interval           # month | year
included_credits   :integer  # ★ credits the plan grants each period
limits             :map
purchasable        :boolean
published_at
```

**Changing the price, included credits, or limits issues a new revision.**
On publish, the previous revision becomes `purchasable = false` and existing
subscriptions are unaffected.

#### Grant amount — `granted_credits/1`
> devkanban `plan_revision.ex:102`

```elixir
# if a credit pack is attached, the pack wins
granted_credits(%{credit_pack_revision: pack}) -> pack.credits + pack.bonus_credits
# otherwise the plan's included_credits
granted_credits(%{included_credits: n}) -> n
granted_credits(_) -> 0
```

**Plans grant credits by default.** While a subscription is active, `MonthlyGrantWorker`
grants `included_credits` each period, and those credits expire at period end
(no rollover).

### Subscription
> devkanban `lib/manualsquad/billing/subscription.ex`

```elixir
account_id                # devkanban uses organization_id
plan_revision_id          # pinned
state                     # active | past_due | paused | canceled
current_period_start / current_period_end
cancel_at, scheduled_change
provider, provider_subscription_id   # placeholder for payment integration
```

One active subscription per account. **On signup, accounts are automatically subscribed
to the latest revision of the Free plan.**

---

## Credits

### CreditLot — a granted bundle
> devkanban `lib/manualsquad/billing/credit_lot.ex`

```elixir
account_id
source        # plan_grant | admin_grant
amount        # granted amount
remaining     # remaining balance (may go negative — overdraft)
expires_at    # nil = never expires
origin        :map
```

### CreditLedgerEntry — append-only
> devkanban `lib/manualsquad/billing/credit_ledger_entry.ex`

```elixir
account_id
delta             # +grant / -usage
source            # plan_grant | admin_grant | usage | expiry | admin_revoke | adjustment
reason, actor_id, credit_lot_id
idempotency_key   # unique — prevents double application

# usage details — snapshotted so it can be recomputed later
charge_domain     # "stt" | "llm"
usage_cost_usd    :decimal
credit_value_usd  :decimal
computed_credits  :decimal   # before rounding
charged_credits   :integer   # actual recorded value
rounding_policy   # "ceil"
pricing_snapshot  :map
```

### Invariant

```
balance = Σ ledger.delta = Σ lot.remaining
```

- **Consumption order: nearest expiry first → FIFO.** Spend expiring plan credits before
  open-ended ones
- **Admin revocation is capped at the current balance**
- **Usage metering allows overdraft** — metering happens after the work is already done,
  so it cannot be blocked. Shortfalls are recorded in a lot with a negative `remaining`
  to preserve the invariant above

### Idempotency
> devkanban `usage_idempotency_key/2`

When one usage event spans multiple lots, there are multiple ledger entries.
`idempotency_key` is unique, so each entry derives its own key.

| Entry | Derived key |
|---|---|
| Deduction from a lot | `<base>:lot:<credit_lot_id>` |
| Shortfall (overdraft) | `<base>:overdraft` |

**The overdraft key never uses a lot id.** Every time a shortfall is recorded, a new lot
is created, so the key would differ each time and the unique constraint would never bite.
The worker would then re-deduct the same usage on every retry. **On the free plan a zero
balance is the normal state**, making this the normal path — meaning this mistake would
not be a rare edge case but something that happens to every user, every time.

Regression test: `test/vr/billing_test.exs` — "usage metering idempotency"

---

## Usage → credit conversion

> **Source: devkanban** `lib/manualsquad/billing/credit_conversion_setting.ex` +
> `credit_conversions.ex`. **We do not use the sisyphus approach (a per-service `cookie_rate`).**

### CreditConversionSetting — singleton

```elixir
singleton_key     "current"   # always exactly one
currency          "USD"
credit_value_usd  :decimal    # 1 credit = $N
rounding_policy   "ceil"      # always round up
```

### Formula

```
computed_credits = usage_cost_usd / credit_value_usd
charged_credits  = ceil(computed_credits)
```

**Why this approach** — sisyphus kept a separate `cookie_rate` per service. That means
recomputing every per-service conversion rate each time a provider's unit price changes.
The devkanban approach **derives from actual USD cost**, so when unit prices change only
the cost calculation needs fixing, and credit policy lives in exactly one place
(`credit_value_usd`).

**Why ceil** — a single policy keeps things simple and no fractional remainder leaks.
devkanban likewise pinned `rounding_policies` to just `["ceil"]`.

### Cost derivation

`usage_cost_usd`, the input to the conversion, is computed by this app directly.

| Target | Cost |
|---|---|
| Transcription | `ceil(duration_seconds / 60)` minutes × per-minute STT price |
| Summary | (input tokens × input price + output tokens × output price) / 1M |

Unit prices are managed in the admin UI → [07-config-admin.md](07-config-admin.md)

---

## Free plan policy

| Item | Value |
|---|---|
| Free plan `included_credits` | **Granted each period** (set in admin) |
| On exhaustion | Keeps working (overdraft) as long as `policy.hard_stop_on_zero_credits` is off |
| User screen | Shows balance and usage history |

**The reason actual billing is zero today** is that the system admin supplies the API
keys — not that no credits are granted. The ledger accumulates precise usage and costs,
so real usage is visible in the admin UI.

**To go paid**, change:
1. Publish paid plans (add `Plan` + `PlanRevision`)
2. Adjust the Free plan's `included_credits` to the free allowance
3. Turn `policy.hard_stop_on_zero_credits` **ON** — reject new requests when out of balance
4. Integrate payments

No schema changes required.

---

## Workers

> devkanban `billing/monthly_grant_worker.ex`, `billing/credit_expiry_worker.ex`

| Worker | Cadence | Behavior |
|---|---|---|
| `MonthlyGrantWorker` | Daily | For each active subscription, grants `granted_credits` expiring at `current_period_end` and rolls the period forward |
| `CreditExpiryWorker` | Daily | Expires lots past `expires_at` and records an `expiry` ledger entry |

---

## Public-facing naming

> devkanban `billing/commerce_settings.ex`

```elixir
CommerceSettings   # singleton
  credit_term      %{singular: "cookie", plural: "cookies", icon: "cookie"}
  plan_term
  locale_overrides
```

Internal code, the DB, and logs always say `credit`; this terminology applies **only at
screen rendering time**.

---

## Auditing

> devkanban `billing/billing_audit_log.ex`

```elixir
actor_id, action, target_type, target_id, before, after, inserted_at
```

Covers: plan publish/retire, revision publish, subscription changes, manual credit
grant/revoke, conversion-rate changes.
Manual credit operations **require a reason** to be entered.

---

## Not ported

These exist in devkanban but are not included in this app. If needed, they can be taken
from the original.

| Item | devkanban original |
|---|---|
| Payments overall | `order.ex` · `payment*.ex` · `payment_provider/` · webhook · refund · reconciliation |
| Credit pack purchases | `credit_pack.ex` · `pack_revision.ex` |
| Auto-recharge | `auto_recharge_*.ex` |
| Enterprise contracts | `enterprise_contract*.ex` |
| Trial conversion | `trial_conversion_worker.ex` |
| Sales windows / previews | `plan_pricing.ex` · `plan_pricing_policy*.ex` |
| Workspace runtime metering | `workspace_runtime_*.ex` |
| Sunset / scheduled change | `sunset_worker.ex` · `scheduled_change_worker.ex` |
