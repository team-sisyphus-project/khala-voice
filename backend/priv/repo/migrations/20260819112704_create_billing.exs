defmodule VR.Repo.Migrations.CreateBilling do
  use Ecto.Migration

  @moduledoc """
  플랜 · 구독 · 크레딧.

  **출처: devkanban** `lib/manualsquad/billing/*` + `docs/billing-commerce-design.md`.
  결제 · 팩 구매 · 오토충전 · 엔터프라이즈는 이식하지 않았다.
  """

  def change do
    # ── 카탈로그 ────────────────────────────────────────────
    create table(:plans, primary_key: false) do
      add :id, :string, primary_key: true
      # 코드에서 참조하는 키. "free" 처럼 고정된 이름
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

    # 불변 상업 스냅샷. 가격·포함 크레딧·한도를 바꾸면 새 행이 생긴다.
    create table(:plan_revisions, primary_key: false) do
      add :id, :string, primary_key: true
      add :plan_id, references(:plans, type: :string, on_delete: :delete_all), null: false
      add :revision, :integer, null: false
      # 통화별 가격. %{"KRW" => %{"amount" => 0}} — minor unit
      add :prices, :map, null: false, default: %{}
      add :interval, :string, null: false, default: "month"
      # 매 기간 지급하는 크레딧
      add :included_credits, :integer, null: false, default: 0
      add :limits, :map, null: false, default: %{}
      add :purchasable, :boolean, null: false, default: true
      add :published_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:plan_revisions, [:plan_id, :revision])
    create index(:plan_revisions, [:plan_id, :purchasable])

    # ── 계약 ────────────────────────────────────────────────
    create table(:subscriptions, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false

      # 핀 고정. 리비전이 새로 나와도 이 구독은 자기 것을 유지한다 (그랜드파더링)
      add :plan_revision_id, references(:plan_revisions, type: :string, on_delete: :restrict),
        null: false

      add :state, :string, null: false, default: "active"
      add :current_period_start, :utc_datetime, null: false
      add :current_period_end, :utc_datetime, null: false
      add :cancel_at, :utc_datetime
      add :scheduled_change, :map

      # 결제 연동 자리. 지금은 비어 있다.
      add :provider, :string
      add :provider_subscription_id, :string

      timestamps(type: :utc_datetime)
    end

    # 계정당 활성 구독은 하나
    create unique_index(:subscriptions, [:account_id],
             where: "state IN ('active','past_due','paused')",
             name: :subscriptions_one_active_per_account
           )

    create index(:subscriptions, [:state, :current_period_end])

    # ── 크레딧 ──────────────────────────────────────────────
    create table(:credit_lots, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :amount, :integer, null: false
      # 잔량. 오버드래프트로 음수가 될 수 있다.
      add :remaining, :integer, null: false
      add :expires_at, :utc_datetime
      add :expired_at, :utc_datetime
      add :origin, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    # FIFO 소비 질의용 — 만료 임박 순, NULL 마지막, 삽입순
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
      # 같은 사용을 두 번 기록하지 않기 위한 열쇠
      add :idempotency_key, :string

      # 사용(usage) 상세 — 나중에 재계산할 수 있게 스냅샷을 남긴다
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

    # ── 환산 정책 (싱글턴) ──────────────────────────────────
    create table(:credit_conversion_settings, primary_key: false) do
      add :id, :string, primary_key: true
      add :singleton_key, :string, null: false, default: "current"
      add :currency, :string, null: false, default: "USD"
      # 1 크레딧 = $N
      add :credit_value_usd, :decimal, null: false
      add :rounding_policy, :string, null: false, default: "ceil"
      add :updated_by_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:credit_conversion_settings, [:singleton_key])

    create constraint(:credit_conversion_settings, :credit_value_positive,
             check: "credit_value_usd > 0"
           )

    # ── 감사 ────────────────────────────────────────────────
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
