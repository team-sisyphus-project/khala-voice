defmodule VR.SharingTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.{Meetings, Sharing}
  alias VR.Sharing.SharedLink

  setup do
    owner = account_fixture()
    {:ok, meeting} = Meetings.create_meeting(owner, %{title: "Meeting to Share"})

    {:ok, meeting} =
      Meetings.update_permissions(meeting, %{guest_link_enabled: true})

    %{owner: owner, meeting: meeting}
  end

  defp issue(ctx, attrs \\ %{}) do
    {:ok, link, token, pin} = Sharing.issue_link(ctx.meeting, ctx.owner, attrs)
    %{link: link, token: token, pin: pin}
  end

  describe "issuing" do
    test "id and token carry prefixes", ctx do
      %{link: link, token: token} = issue(ctx)

      assert String.starts_with?(link.id, "slnk_")
      assert String.starts_with?(token, "slt_")
    end

    test "plaintext token appears nowhere in the DB", ctx do
      %{token: token} = issue(ctx)

      # The token is a credential that works without further auth. Reading the DB must not make you a visitor.
      raw = String.replace_prefix(token, "slt_", "")

      dumped =
        Repo.all(SharedLink)
        |> Enum.map(&inspect(&1, limit: :infinity, printable_limit: :infinity))
        |> Enum.join("\n")

      refute String.contains?(dumped, raw)
      refute String.contains?(dumped, token)
    end

    test "with PIN enabled, the plaintext exists only in the issue response", ctx do
      %{link: link, pin: pin} = issue(ctx, %{"with_pincode" => true})

      assert String.match?(pin, ~r/^\d{6}$/)
      assert link.pin_hash
      refute String.contains?(link.pin_hash, pin)
    end

    test "issuing without a PIN leaves pin_hash empty", ctx do
      %{link: link, pin: pin} = issue(ctx)

      assert is_nil(pin)
      assert is_nil(link.pin_hash)
    end

    test "the reviewer role cannot be granted", ctx do
      # A single link must not hand over delete-level permissions
      assert {:error, changeset} =
               Sharing.issue_link(ctx.meeting, ctx.owner, %{"granted_role" => "reviewer"})

      assert %{granted_role: _} = errors_on(changeset)
    end

    test "the request body cannot set use counts or tokens", ctx do
      {:ok, link, _token, _pin} =
        Sharing.issue_link(ctx.meeting, ctx.owner, %{
          "use_count" => 99,
          "token_hash" => "fake",
          "id" => "slnk_my_chosen_id",
          "meeting_id" => "meet_someone_elses"
        })

      assert link.use_count == 0
      assert link.id != "slnk_my_chosen_id"
      assert link.meeting_id == ctx.meeting.id
    end

    test "rejects an expiry time in the past", ctx do
      past = DateTime.add(DateTime.utc_now(:second), -60, :second)

      assert {:error, _} =
               Sharing.issue_link(ctx.meeting, ctx.owner, %{"expires_at" => past})
    end
  end

  describe "role cannot be escalated later" do
    test "changing granted_role via update_link is ignored", ctx do
      # Upgrading an already-distributed viewer link to contributor would
      # retroactively escalate permissions for everyone holding it
      %{link: link} = issue(ctx, %{"granted_role" => "viewer"})

      {:ok, updated} = Sharing.update_link(link, %{"granted_role" => "contributor"})

      assert updated.granted_role == "viewer"
    end
  end

  describe "use count" do
    test "concurrent entries do not exceed max_uses", ctx do
      %{link: link} = issue(ctx, %{"max_uses" => 1})

      # ⚠ The sandbox owner is the **test process**. Passing `self()` as owner from
      # inside a task lets that connection escape the sandbox and commit to the test DB for real.
      owner = self()

      results =
        1..8
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(VR.Repo, owner, self())
            Sharing.consume_use(link)
          end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # Check and increment are one statement, so exactly one passes even under contention
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :gone}, &1)) == 7
    end

    test "no more entries once exhausted", ctx do
      %{link: link} = issue(ctx, %{"max_uses" => 1})

      assert {:ok, _} = Sharing.consume_use(link)
      assert {:error, :gone} = Sharing.consume_use(link)
    end
  end

  describe "entering" do
    test "receives a guest token bound to that meeting only", ctx do
      %{token: token} = issue(ctx, %{"granted_role" => "contributor"})

      assert {:ok, result} = Sharing.enter(token, %{"display_name" => "Guest"})
      assert result.mode == :guest
      assert String.starts_with?(result.guest_token, "gst_")
      assert result.meeting_id == ctx.meeting.id

      {:ok, session} = Sharing.fetch_live_guest(result.guest_token)
      assert session.meeting_id == ctx.meeting.id
      assert session.granted_role == "contributor"
    end

    test "cannot enter without a name when one is required", ctx do
      %{token: token} = issue(ctx, %{"require_name" => true})

      assert {:error, changeset} = Sharing.enter(token, %{})
      assert %{display_name: _} = errors_on(changeset)
    end

    test "links that do not ask for a name let you straight in", ctx do
      %{token: token} = issue(ctx, %{"require_name" => false})
      assert {:ok, %{mode: :guest}} = Sharing.enter(token, %{})
    end

    test "404 when the meeting switch is off (not 410)", ctx do
      {:ok, _} = Meetings.update_permissions(ctx.meeting, %{guest_link_enabled: false})
      %{token: token} = issue(ctx, %{"require_name" => false})

      # Does not even reveal that the link used to be valid
      assert {:error, :not_found} = Sharing.enter(token, %{})
    end

    test "unknown token is 404", ctx do
      _ = ctx
      assert {:error, :not_found} = Sharing.enter("slt_nonexistent", %{})
      assert {:error, :not_found} = Sharing.enter("not-even-the-format", %{})
    end

    test "revoked link is 410", ctx do
      %{link: link, token: token} = issue(ctx, %{"require_name" => false})
      {:ok, _} = Sharing.revoke_link(link)

      assert {:error, :gone} = Sharing.enter(token, %{})
    end

    test "use count is not burned when session creation fails", ctx do
      # A one-shot link must not die from a single missing-name attempt
      %{link: link, token: token} = issue(ctx, %{"max_uses" => 1, "require_name" => true})

      assert {:error, _} = Sharing.enter(token, %{})
      assert Sharing.get_link(link.id).use_count == 0

      assert {:ok, %{mode: :guest}} = Sharing.enter(token, %{"display_name" => "Guest"})
      assert Sharing.get_link(link.id).use_count == 1
    end

    test "logged-in accounts do not create guest sessions", ctx do
      %{token: token} = issue(ctx, %{"require_name" => false})

      assert {:ok, result} = Sharing.enter(token, %{}, account: ctx.owner)
      assert result.mode == :account
      assert is_nil(result.guest_token)
      # and the use count is not burned either
      assert Sharing.fetch_by_token(token) |> elem(1) |> Map.get(:use_count) == 0
    end
  end

  describe "PIN" do
    test "passes when correct", ctx do
      %{link: link, pin: pin} = issue(ctx, %{"with_pincode" => true})
      assert :ok = Sharing.verify_pincode(link, pin, "1.2.3.4")
    end

    test "rejects when wrong", ctx do
      %{link: link} = issue(ctx, %{"with_pincode" => true})
      assert {:error, :invalid_pincode} = Sharing.verify_pincode(link, "000000", "1.2.3.4")
    end

    test "rejects when no PIN is submitted", ctx do
      %{link: link} = issue(ctx, %{"with_pincode" => true})
      assert {:error, :invalid_pincode} = Sharing.verify_pincode(link, nil, "1.2.3.4")
    end

    test "locks after 5 failures and even the correct PIN stops working", ctx do
      %{link: link, pin: pin} = issue(ctx, %{"with_pincode" => true})

      for _ <- 1..5 do
        assert {:error, :invalid_pincode} =
                 Sharing.verify_pincode(Sharing.get_link(link.id), "000000", "9.9.9.9")
      end

      locked = Sharing.get_link(link.id)
      assert {:error, :locked} = Sharing.verify_pincode(locked, pin, "9.9.9.9")
    end

    test "links without a PIN accept whatever is submitted", ctx do
      %{link: link} = issue(ctx)
      assert :ok = Sharing.verify_pincode(link, nil, "1.2.3.4")
      assert :ok = Sharing.verify_pincode(link, "anything", "1.2.3.4")
    end

    test "re-enabling the PIN changes the value and clears the lock", ctx do
      %{link: link} = issue(ctx, %{"with_pincode" => true})

      {:ok, link, first} = Sharing.set_pincode(link, :on)
      {:ok, link, second} = Sharing.set_pincode(link, :on)

      assert first != second
      assert link.failed_pin_attempts == 0
      assert is_nil(link.pin_locked_until)
    end

    test "disabling the PIN removes the hash", ctx do
      %{link: link} = issue(ctx, %{"with_pincode" => true})

      {:ok, updated, pin} = Sharing.set_pincode(link, :off)
      assert is_nil(pin)
      assert is_nil(updated.pin_hash)
    end
  end

  describe "revocation vs. exhaustion" do
    test "revoking also cuts off guests who already entered", ctx do
      %{link: link, token: token} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})

      assert {:ok, _} = Sharing.fetch_live_guest(guest_token)

      {:ok, _} = Sharing.revoke_link(link)

      assert :error = Sharing.fetch_live_guest(guest_token)
    end

    test "exhaustion keeps guests who already entered", ctx do
      # "No new entries" and "evict those inside" are different things.
      # If someone who got the minutes via a one-shot link were kicked on the second request, the link would be useless.
      %{token: token} = issue(ctx, %{"max_uses" => 1, "require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})

      assert {:error, :gone} = Sharing.enter(token, %{})
      assert {:ok, _} = Sharing.fetch_live_guest(guest_token)
    end
  end

  describe "rotation" do
    test "the old token dies, guests stay alive", ctx do
      %{link: link, token: old} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(old, %{})

      {:ok, _updated, new} = Sharing.rotate_token(link)

      assert {:error, :not_found} = Sharing.fetch_by_token(old)
      assert {:ok, _} = Sharing.fetch_by_token(new)
      # Rotation means "the address was lost", not "kick everyone out"
      assert {:ok, _} = Sharing.fetch_live_guest(guest_token)
    end

    test "settings and use count are preserved", ctx do
      %{link: link} = issue(ctx, %{"max_uses" => 5, "granted_role" => "contributor"})
      {:ok, link} = Sharing.consume_use(link)

      {:ok, updated, _} = Sharing.rotate_token(link)

      assert updated.use_count == 1
      assert updated.max_uses == 5
      assert updated.granted_role == "contributor"
    end
  end

  describe "guest authorization" do
    test "only the bound meeting opens", ctx do
      %{token: token} = issue(ctx, %{"granted_role" => "viewer", "require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})
      {:ok, session} = Sharing.fetch_live_guest(guest_token)

      assert {:ok, meeting, :lv2} = Sharing.guest_authorize(session, :lv2)
      assert meeting.id == ctx.meeting.id

      # A viewer guest demanding contributor permission gets 404 (not 403)
      assert {:error, :not_found} = Sharing.guest_authorize(session, :lv1)
    end

    test "planting another meeting id in the session does not work", ctx do
      %{token: token} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})
      {:ok, session} = Sharing.fetch_live_guest(guest_token)

      other_owner = account_fixture()
      {:ok, other} = Meetings.create_meeting(other_owner, %{title: "Someone Else's Meeting"})

      tampered = %{session | meeting_id: other.id}

      # Even when the session points at another meeting, it cannot open one whose guest switch is off
      assert {:error, :not_found} = Sharing.guest_authorize(tampered, :lv2)
    end

    test "turning the meeting switch off also blocks guests who already entered", ctx do
      %{token: token} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})
      {:ok, session} = Sharing.fetch_live_guest(guest_token)

      assert {:ok, _, _} = Sharing.guest_authorize(session, :lv2)

      {:ok, _} = Meetings.update_permissions(ctx.meeting, %{guest_link_enabled: false})

      assert {:error, :not_found} = Sharing.guest_authorize(session, :lv2)
    end
  end

  describe "PIN generation" do
    test "can produce 000000 and is always 6 digits" do
      pins = for _ <- 1..300, do: SharedLink.generate_pincode()

      assert Enum.all?(pins, &String.match?(&1, ~r/^\d{6}$/))
      # sisyphus used 100_001..999_999, so a leading 0 could never appear
      assert Enum.uniq(pins) |> length() > 200
    end
  end

  describe "findings from adversarial review" do
    test "merely logging in cannot bypass the guest-block switch", ctx do
      # The switch means "this meeting accepts no guests".
      # Making login an exemption would let anyone sign up to bypass it, burning the
      # one-shot link so the legitimate recipient can no longer get in.
      {:ok, _} = Meetings.update_permissions(ctx.meeting, %{guest_link_enabled: false})
      %{link: link, token: token} = issue(ctx, %{"max_uses" => 1, "require_name" => false})

      stranger = account_fixture()

      assert {:error, :not_found} = Sharing.enter(token, %{}, account: stranger)
      # and the use count is not burned either
      assert Sharing.get_link(link.id).use_count == 0
    end

    test "accounts without permission must still pass the PIN", ctx do
      # The account entry path used to discard the request body entirely, so
      # (a) logged-in users could never enter PIN-protected links, and
      # (b) those failures burned the lock counter, blocking legitimate guests too
      %{token: token, pin: pin} =
        issue(ctx, %{"with_pincode" => true, "require_name" => false})

      stranger = account_fixture()

      assert {:error, :invalid_pincode} =
               Sharing.enter(token, %{"pincode" => "000000"}, account: stranger)

      assert {:ok, %{mode: :guest}} =
               Sharing.enter(token, %{"pincode" => pin}, account: stranger)
    end

    test "accounts without permission can still submit a name", ctx do
      %{token: token} = issue(ctx, %{"require_name" => true})
      stranger = account_fixture()

      assert {:ok, %{mode: :guest}} =
               Sharing.enter(token, %{"display_name" => "Guest"}, account: stranger)
    end

    test "PIN lockout does not collapse under concurrent requests", ctx do
      # Read-then-+1 lets concurrent requests overwrite each other's increments (lost
      # update), so the lock never engages. A 6-digit PIN becomes brute-forceable then.
      %{link: link, pin: pin} = issue(ctx, %{"with_pincode" => true})
      owner = self()

      1..10
      |> Task.async_stream(
        fn _ ->
          Ecto.Adapters.SQL.Sandbox.allow(VR.Repo, owner, self())
          Sharing.verify_pincode(Sharing.get_link(link.id), "000000", nil)
        end,
        max_concurrency: 10
      )
      |> Stream.run()

      locked = Sharing.get_link(link.id)
      assert locked.failed_pin_attempts >= SharedLink.pin_max_failures()
      assert SharedLink.pin_locked?(locked)
      # Once locked, even the correct PIN does not pass
      assert {:error, :locked} = Sharing.verify_pincode(locked, pin, nil)
    end

    test "deactivating the link also cuts off guests who already entered", ctx do
      # A control the reviewer believes "turned it off" must not be a no-op
      %{link: link, token: token} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})

      assert {:ok, _} = Sharing.fetch_live_guest(guest_token)

      {:ok, _} = Sharing.update_link(link, %{"is_active" => false})

      assert :error = Sharing.fetch_live_guest(guest_token)
    end

    test "moving the link expiry earlier also cuts off guests who already entered", ctx do
      %{link: link, token: token} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})

      # The changeset rejects past times, so change the DB directly (operator set it short, then time passed)
      past = DateTime.add(DateTime.utc_now(:second), -60, :second)
      link |> Ecto.Changeset.change(%{expires_at: past}) |> Repo.update!()

      assert :error = Sharing.fetch_live_guest(guest_token)
    end

    test "exhaustion still does not evict guests who already entered", ctx do
      # If fixing the two above breaks this distinction, one-shot links become useless
      %{token: token} = issue(ctx, %{"max_uses" => 1, "require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})

      assert {:error, :gone} = Sharing.enter(token, %{})
      assert {:ok, _} = Sharing.fetch_live_guest(guest_token)
    end
  end
end
