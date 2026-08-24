defmodule VR.Workers.AdminAuditRetentionWorkerTest do
  use VR.DataCase, async: true

  alias VR.AdminAudit
  alias VR.AdminAudit.Event
  alias VR.Repo
  alias VR.Workers.AdminAuditRetentionWorker

  test "performs the daily online-retention purge" do
    {:ok, event} =
      AdminAudit.record(%{
        action: "account.delete",
        outcome: "denied",
        reason: "unauthorized",
        actor_account_id: "acct_actor",
        target_account_id: "acct_target",
        actor_email: "actor@example.test",
        target_email: "target@example.test",
        request_id: "retention-test",
        occurred_at: DateTime.add(DateTime.utc_now(:second), -366, :day)
      })

    assert :ok = perform_job(AdminAuditRetentionWorker, %{})
    refute Repo.get(Event, event.event_id)
  end
end
