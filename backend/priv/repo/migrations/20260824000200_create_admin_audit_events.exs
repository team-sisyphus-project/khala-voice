defmodule VR.Repo.Migrations.CreateAdminAuditEvents do
  use Ecto.Migration

  def change do
    create table(:admin_audit_events, primary_key: false) do
      add :event_id, :uuid, primary_key: true
      add :occurred_at, :utc_datetime, null: false
      add :action, :string, null: false
      add :outcome, :string, null: false
      add :reason, :string, null: false
      add :actor_account_id, :string, null: false
      add :target_account_id, :string, null: false
      add :actor_email_masked, :string, null: false
      add :target_email_masked, :string, null: false
      add :request_id, :string, null: false
    end

    create constraint(:admin_audit_events, :admin_audit_events_action_check,
             check: "action IN ('admin.promote', 'admin.demote', 'account.delete')"
           )

    create constraint(:admin_audit_events, :admin_audit_events_outcome_check,
             check: "outcome IN ('succeeded', 'denied')"
           )

    create constraint(:admin_audit_events, :admin_audit_events_reason_check,
             check:
               "reason IN ('completed', 'unauthorized', 'recent_mfa_required', " <>
                 "'account_deleted', 'already_admin', 'not_admin', 'cannot_demote_self', " <>
                 "'cannot_delete_self', 'last_admin', 'already_deleted', 'audit_write_failed')"
           )

    create index(:admin_audit_events, [:occurred_at, :event_id])
    create index(:admin_audit_events, [:action])
    create index(:admin_audit_events, [:outcome])
    create index(:admin_audit_events, [:reason])
    create index(:admin_audit_events, [:actor_account_id])
    create index(:admin_audit_events, [:target_account_id])
    create index(:admin_audit_events, [:request_id])
  end
end
