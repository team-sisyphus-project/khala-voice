defmodule VR.Repo.Migrations.CreateBilling do
  use Ecto.Migration

  @moduledoc """
  Plans · subscriptions · credits.

  **Source: devkanban** `lib/manualsquad/billing/*` + `docs/billing-commerce-design.md`.
  Payments · pack purchases · auto-top-up · enterprise were not ported.
  """

  def change do
    # ── Catalog ─────────────────────────────────────────────
    create table(:plans, primary_key: false) do
      add :id, :string, primary_key: true
      # Key referenced from code. A fixed name like "free"
      add :key, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :display_name, :string, null: false
      add :description, :text
      add :name_i18n, :map, null: false, default: %{}
      add :description_i18n, :map, null: false, default: %{}
      add :icon, :string
      add :sort_order, :integer, null: false, default: 0
      add :publicly_listed, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:plans, [:key])
    create index(:plans, [:status])

    # Immutable commercial snapshot. Changing prices/included credits/limits creates a new row.
    create table(:plan_revisions, primary_key: false) do
      add :id, :string, primary_key: true
      add :plan_id, references(:plans, type: :string, on_delete: :delete_all), null: false
      add :revision, :integer, null: false
      # Prices per currency. %{"KRW" => %{"amount" => 0}} — minor units
      add :prices, :map, null: false, default: %{}
      add :interval, :string, null: false, default: "month"
      # Credits granted every period
      add :included_credits, :integer, null: false, default: 0
      add :limits, :map, null: false, default: %{}
      add :purchasable, :boolean, null: false, default: true
      add :published_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:plan_revisions, [:plan_id, :revision])
    create index(:plan_revisions, [:plan_id, :purchasable])

    # ── Contracts ───────────────────────────────────────────
    create table(:subscriptions, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false

      # Pinned. Even when a new revision ships, this subscription keeps its own (grandfathering)
      add :plan_revision_id, references(:plan_revisions, type: :string, on_delete: :restrict),
        null: false

      add :state, :string, null: false, default: "active"
      add :current_period_start, :utc_datetime, null: false
      add :current_period_end, :utc_datetime, null: false
      add :cancel_at, :utc_datetime
      add :scheduled_change, :map

      # Slot for payment integration. Empty for now.
      add :provider, :string
      add :provider_subscription_id, :string

      timestamps(type: :utc_datetime)
    end

    # One active subscription per account
    create unique_index(:subscriptions, [:account_id],
             where: "state IN ('active','past_due','paused')",
             name: :subscriptions_one_active_per_account
           )

    create index(:subscriptions, [:state, :current_period_end])

    # ── Credits ─────────────────────────────────────────────
    create table(:credit_lots, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :amount, :integer, null: false
      # Remaining balance. May go negative via overdraft.
      add :remaining, :integer, null: false
      add :expires_at, :utc_datetime
      add :expired_at, :utc_datetime
      add :origin, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    # For FIFO consumption queries — soonest expiry first, NULLs last, then insertion order
    create index(:credit_lots, [:account_id, :expires_at, :inserted_at])
    create index(:credit_lots, [:expires_at], where: "expired_at IS NULL")

    create table(:credit_ledger_entries, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false
      add :credit_lot_id, references(:credit_lots, type: :string, on_delete: :nilify_all)
      add :delta, :integer, null: false
      add :source, :string, null: false
      add :reason, :string
      add :actor_id, :string
      # Key that keeps the same usage from being recorded twice
      add :idempotency_key, :string

      # Usage detail — snapshotted so it can be recomputed later
      add :charge_domain, :string
      add :usage_cost_usd, :decimal
      add :credit_value_usd, :decimal
      add :computed_credits, :decimal
      add :charged_credits, :integer
      add :rounding_policy, :string
      add :pricing_snapshot, :map

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:credit_ledger_entries, [:idempotency_key],
             where: "idempotency_key IS NOT NULL"
           )

    create index(:credit_ledger_entries, [:account_id, :inserted_at])

    # ── Conversion policy (singleton) ───────────────────────
    create table(:credit_conversion_settings, primary_key: false) do
      add :id, :string, primary_key: true
      add :singleton_key, :string, null: false, default: "current"
      add :currency, :string, null: false, default: "USD"
      # 1 credit = $N
      add :credit_value_usd, :decimal, null: false
      add :rounding_policy, :string, null: false, default: "ceil"
      add :updated_by_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:credit_conversion_settings, [:singleton_key])

    create constraint(:credit_conversion_settings, :credit_value_positive,
             check: "credit_value_usd > 0"
           )

    # ── Audit ───────────────────────────────────────────────
    create table(:billing_audit_logs, primary_key: false) do
      add :id, :string, primary_key: true
      add :actor_id, :string
      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :string
      add :before, :map
      add :after, :map

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:billing_audit_logs, [:inserted_at])
    create index(:billing_audit_logs, [:target_type, :target_id])
  end
end
