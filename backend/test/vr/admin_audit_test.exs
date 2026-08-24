defmodule VR.AdminAuditTest do
  use VR.DataCase, async: true

  alias VR.AdminAudit
  alias VR.AdminAudit.Event
  alias VR.Repo

  defp event_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        action: "admin.promote",
        outcome: "succeeded",
        reason: "completed",
        actor_account_id: "acct_actor",
        target_account_id: "acct_target",
        actor_email: " Alice.Example@Sub.Example.com ",
        target_email: "Bob@example.test",
        request_id: "request-1",
        occurred_at: ~U[2026-08-24 12:00:00Z]
      },
      overrides
    )
  end

  describe "record/1" do
    test "stores only masked email snapshots and the policy schema" do
      assert {:ok, event} = AdminAudit.record(event_attrs())

      assert event.actor_email_masked == "a***@***.com"
      assert event.target_email_masked == "b***@***.test"
      refute inspect(event) =~ "Alice.Example"

      %{rows: [[actor_email, target_email]]} =
        Repo.query!(
          "SELECT actor_email_masked, target_email_masked FROM admin_audit_events WHERE event_id = $1",
          [Ecto.UUID.dump!(event.event_id)]
        )

      assert actor_email == "a***@***.com"
      assert target_email == "b***@***.test"
    end

    test "redacts invalid email addresses" do
      assert {:ok, event} =
               AdminAudit.record(
                 event_attrs(%{actor_email: "a@localhost", target_email: "not-an-email"})
               )

      assert event.actor_email_masked == "[redacted]"
      assert event.target_email_masked == "[redacted]"
    end

    test "rejects values outside the fixed action, outcome, and reason sets" do
      assert {:error, changeset} = AdminAudit.record(event_attrs(%{action: "admin.arbitrary"}))
      assert "is invalid" in errors_on(changeset).action
    end
  end

  describe "search/1" do
    test "combines exact and time-range filters in deterministic newest-first order" do
      {:ok, older} = AdminAudit.record(event_attrs(%{event_id: Ecto.UUID.generate()}))

      {:ok, newer} =
        AdminAudit.record(
          event_attrs(%{
            event_id: Ecto.UUID.generate(),
            action: "admin.demote",
            outcome: "denied",
            reason: "last_admin",
            occurred_at: ~U[2026-08-24 13:00:00Z],
            request_id: "request-2"
          })
        )

      assert {:ok, [^newer]} =
               AdminAudit.search(
                 action: "admin.demote",
                 outcome: "denied",
                 reason: "last_admin",
                 actor_account_id: "acct_actor",
                 target_account_id: "acct_target",
                 request_id: "request-2",
                 occurred_from: ~U[2026-08-24 12:30:00Z],
                 occurred_until: ~U[2026-08-24 13:30:00Z]
               )

      assert {:ok, [^newer]} = AdminAudit.search(event_id: newer.event_id)
      assert {:ok, [^newer, ^older]} = AdminAudit.search([])
    end

    test "does not expose email search" do
      assert {:error, {:unsupported_filters, [:actor_email]}} =
               AdminAudit.search(actor_email: "alice@example.com")
    end
  end

  describe "purge_expired/1" do
    test "deletes events at least 365 days old and retains newer events" do
      now = ~U[2026-08-24 12:00:00Z]

      {:ok, expired} =
        AdminAudit.record(
          event_attrs(%{event_id: Ecto.UUID.generate(), occurred_at: ~U[2025-08-24 12:00:00Z]})
        )

      {:ok, retained} =
        AdminAudit.record(
          event_attrs(%{event_id: Ecto.UUID.generate(), occurred_at: ~U[2025-08-24 12:00:01Z]})
        )

      assert 1 = AdminAudit.purge_expired(now)
      refute Repo.get(Event, expired.event_id)
      assert Repo.get(Event, retained.event_id)
    end
  end
end
