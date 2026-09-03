defmodule VR.MeetingsTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.{Friends, Meetings}

  setup do
    reviewer = account_fixture(name: "Reviewer")
    contributor = account_fixture(name: "Contributor")
    friend = account_fixture(name: "Friend")
    stranger = account_fixture(name: "Stranger")

    {:ok, _} = Friends.create_friendship(reviewer.id, friend.id)
    {:ok, meeting} = Meetings.create_meeting(reviewer, %{title: "Weekly Sync"})

    {:ok, meeting} =
      Meetings.update_permissions(meeting, %{contributor_ids: [contributor.id]})

    %{
      reviewer: reviewer,
      contributor: contributor,
      friend: friend,
      stranger: stranger,
      meeting: meeting
    }
  end

  describe "creation" do
    test "the creator becomes the Reviewer", %{reviewer: reviewer} do
      {:ok, m} = Meetings.create_meeting(reviewer, %{})
      assert m.owner_id == reviewer.id
      assert m.reviewer_id == reviewer.id
      assert m.status == "active"
      assert String.starts_with?(m.id, "meet_")
    end

    test "fills in a date-based title when none is given", %{reviewer: reviewer} do
      {:ok, m} = Meetings.create_meeting(reviewer, %{})
      assert m.title =~ "Meeting"
    end

    test "the default visibility is assignees-only", %{reviewer: reviewer} do
      {:ok, m} = Meetings.create_meeting(reviewer, %{})
      assert get_in(m.permissions, ["view", "mode"]) == "assignees_only"
    end
  end

  describe "permissions (Reviewer / Contributor / Viewer)" do
    test "Reviewer is lv0", ctx do
      assert Meetings.level(ctx.meeting, ctx.reviewer) == :lv0
    end

    test "Contributor is lv1", ctx do
      assert Meetings.level(ctx.meeting, ctx.contributor) == :lv1
    end

    test "even friends cannot see assignees-only meetings", ctx do
      assert Meetings.level(ctx.meeting, ctx.friend) == :lv3
    end

    test "switching to all-friends makes friends Viewers", ctx do
      {:ok, m} =
        Meetings.update_permissions(ctx.meeting, %{
          permissions: %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
        })

      assert Meetings.level(m, ctx.friend) == :lv2
      # Non-friends still have no access
      assert Meetings.level(m, ctx.stranger) == :lv3
    end

    test "selected-friends visibility", ctx do
      {:ok, m} =
        Meetings.update_permissions(ctx.meeting, %{
          permissions: %{
            "view" => %{"mode" => "selected_friends", "accountIds" => [ctx.friend.id]}
          }
        })

      assert Meetings.level(m, ctx.friend) == :lv2
      assert Meetings.level(m, ctx.stranger) == :lv3
    end

    test "in me-only mode a Contributor is still lv1", ctx do
      {:ok, m} =
        Meetings.update_permissions(ctx.meeting, %{
          permissions: %{"view" => %{"mode" => "me_only", "accountIds" => []}}
        })

      assert Meetings.level(m, ctx.reviewer) == :lv0
      assert Meetings.level(m, ctx.contributor) == :lv1
      assert Meetings.level(m, ctx.friend) == :lv3
    end

    test "admins are always lv0", ctx do
      admin = account_fixture()
      admin = %{admin | is_admin: true}
      assert Meetings.level(ctx.meeting, admin) == :lv0
    end

    test "guests get the role the link granted", ctx do
      bound = [guest_resource_id: ctx.meeting.id]

      assert Meetings.level(ctx.meeting, nil, [guest_role: "viewer"] ++ bound) == :lv2
      assert Meetings.level(ctx.meeting, nil, [guest_role: "contributor"] ++ bound) == :lv1
      assert Meetings.level(ctx.meeting, nil) == :lv3
    end

    test "guest roles are valid only for the bound meeting", ctx do
      # One guest token must not open a different meeting.
      # The normal path is blocked by VR.Sharing.guest_authorize/2, but if a
      # call site is missed it should still fail closed.
      assert Meetings.level(ctx.meeting, nil, guest_role: "contributor") == :lv3

      assert Meetings.level(ctx.meeting, nil,
               guest_role: "contributor",
               guest_resource_id: "meet_another_meeting"
             ) == :lv3
    end

    test "guests cannot be given reviewer", ctx do
      # A single link must not hand over delete-level permissions
      assert Meetings.level(ctx.meeting, nil,
               guest_role: "reviewer",
               guest_resource_id: ctx.meeting.id
             ) == :lv3
    end
  end

  describe "authorize/4" do
    test "insufficient permission yields not_found (not 403)", ctx do
      assert {:error, :not_found} = Meetings.authorize(ctx.meeting.id, ctx.stranger, :lv2)
    end

    test "nonexistent meetings are also not_found", ctx do
      assert {:error, :not_found} = Meetings.authorize("meet_nope", ctx.reviewer, :lv2)
    end

    test "returns the meeting and level when sufficient", ctx do
      assert {:ok, m, :lv1} = Meetings.authorize(ctx.meeting.id, ctx.contributor, :lv1)
      assert m.id == ctx.meeting.id
    end

    test "a Contributor cannot perform lv0-required actions", ctx do
      assert {:error, :not_found} = Meetings.authorize(ctx.meeting.id, ctx.contributor, :lv0)
    end
  end

  describe "listing" do
    test "the Reviewer sees their own meetings", ctx do
      ids = Meetings.list_meetings(ctx.reviewer) |> Enum.map(& &1.id)
      assert ctx.meeting.id in ids
    end

    test "the Contributor sees them too", ctx do
      ids = Meetings.list_meetings(ctx.contributor) |> Enum.map(& &1.id)
      assert ctx.meeting.id in ids
    end

    test "unrelated people see nothing", ctx do
      assert Meetings.list_meetings(ctx.stranger) == []
    end

    test "friends appear in the list when visibility is all-friends", ctx do
      {:ok, _} =
        Meetings.update_permissions(ctx.meeting, %{
          permissions: %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
        })

      ids = Meetings.list_meetings(ctx.friend) |> Enum.map(& &1.id)
      assert ctx.meeting.id in ids
    end

    test "archived meetings are hidden by default", ctx do
      {:ok, _} = Meetings.set_status(ctx.meeting, "archived")
      assert Meetings.list_meetings(ctx.reviewer) == []
      assert [_] = Meetings.list_meetings(ctx.reviewer, status: "archived")
    end

    test "filters by topic, period, and search term", ctx do
      assert [_] = Meetings.list_meetings(ctx.reviewer, q: "Weekly")
      assert [] = Meetings.list_meetings(ctx.reviewer, q: "nonexistentword")
    end
  end

  describe "recording sessions" do
    test "indexes run consecutively from 1", ctx do
      {:ok, s1} = Meetings.create_session(ctx.meeting)
      {:ok, s2} = Meetings.create_session(ctx.meeting)
      assert s1.session_index == 1
      assert s2.session_index == 2
      assert String.starts_with?(s1.id, "mrss_")
    end

    test "pending while any session still awaits transcription", ctx do
      # Long meetings split every 20 minutes into several chunks that finish minutes apart.
      # Auto-summarize must not start while any remain — a half summary would be saved and
      # later chunks would be skipped as "already summarized", never refreshed.
      {:ok, s1} = Meetings.create_session(ctx.meeting)
      {:ok, s2} = Meetings.create_session(ctx.meeting)

      assert Meetings.transcription_pending?(ctx.meeting.id)

      {:ok, _} = Meetings.set_session_status(s1, "completed")
      assert Meetings.transcription_pending?(ctx.meeting.id), "s2 is still outstanding"

      {:ok, _} = Meetings.set_session_status(s2, "completed")
      refute Meetings.transcription_pending?(ctx.meeting.id)
    end

    test "failed sessions are not waited on", ctx do
      # Failure is a terminal state. Waiting here means the summary never arrives.
      {:ok, s1} = Meetings.create_session(ctx.meeting)
      {:ok, _} = Meetings.set_session_status(s1, "failed")

      refute Meetings.transcription_pending?(ctx.meeting.id)
    end

    test "registering an upload moves status to uploaded", ctx do
      {:ok, session} = Meetings.create_session(ctx.meeting)
      assert session.status == "recording"

      {:ok, updated} =
        Meetings.register_upload(with_storage_key(session), %{
          duration_seconds: 120,
          file_size_bytes: 1_024_000,
          mime_type: "audio/webm"
        })

      assert updated.status == "uploaded"
      assert updated.duration_seconds == 120
    end

    test "totals are cached on the meeting", ctx do
      {:ok, s1} = Meetings.create_session(ctx.meeting)
      {:ok, s2} = Meetings.create_session(ctx.meeting)

      {:ok, _} =
        Meetings.register_upload(with_storage_key(s1), %{
          duration_seconds: 100,
          file_size_bytes: 1,
          mime_type: "audio/webm"
        })

      {:ok, _} =
        Meetings.register_upload(with_storage_key(s2), %{
          duration_seconds: 50,
          file_size_bytes: 1,
          mime_type: "audio/webm"
        })

      {:ok, meeting} = Meetings.recalculate_totals(ctx.meeting)
      assert meeting.total_duration_seconds == 150
    end

    test "deleted sessions drop out of the totals", ctx do
      {:ok, s1} = Meetings.create_session(ctx.meeting)

      {:ok, _} =
        Meetings.register_upload(with_storage_key(s1), %{
          duration_seconds: 100,
          file_size_bytes: 1,
          mime_type: "audio/webm"
        })

      {:ok, _} = Meetings.delete_session(s1)

      {:ok, meeting} = Meetings.recalculate_totals(ctx.meeting)
      assert meeting.total_duration_seconds == 0
      assert Meetings.list_sessions(ctx.meeting.id) == []
    end
  end

  describe "transcript validation" do
    setup ctx do
      {:ok, session} = Meetings.create_session(ctx.meeting)
      Map.put(ctx, :session, session)
    end

    test "valid segments are saved", %{session: session} do
      transcript = %{
        "segments" => [
          %{"speaker" => "speaker_1", "text" => "Hello", "start_ms" => 0, "end_ms" => 1500}
        ]
      }

      assert {:ok, updated} = Meetings.update_transcript(session, %{transcript: transcript})
      assert length(updated.transcript["segments"]) == 1
    end

    test "malformed segments are rejected", %{session: session} do
      bad = %{"segments" => [%{"speaker" => "s1"}]}
      assert {:error, changeset} = Meetings.update_transcript(session, %{transcript: bad})
      assert errors_on(changeset).transcript
    end

    test "rejects a transcript without a segments array", %{session: session} do
      assert {:error, changeset} =
               Meetings.update_transcript(session, %{transcript: %{"foo" => 1}})

      assert errors_on(changeset).transcript
    end
  end

  describe "list and detail decisions agree" do
    test "handing off the Reviewer removes it from the list too", %{reviewer: account} do
      other = account_fixture()
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "Meeting to Hand Off"})

      # The creator is both owner and Reviewer
      assert Enum.any?(Meetings.list_meetings(account), &(&1.id == meeting.id))

      # Hand off only the Reviewer. owner_id stays put.
      {:ok, meeting} =
        Meetings.update_permissions(meeting, %{
          reviewer_id: other.id,
          permissions: %{"view" => %{"mode" => "assignees_only", "accountIds" => []}}
        })

      # AccessLevel does not look at owner_id. The list must agree —
      # otherwise you get "visible in the list but 404 on open".
      assert Meetings.level(meeting, account) == :lv3
      refute Enum.any?(Meetings.list_meetings(account), &(&1.id == meeting.id))

      assert Meetings.level(meeting, other) == :lv0
      assert Enum.any?(Meetings.list_meetings(other), &(&1.id == meeting.id))
    end

    test "every meeting in the list can be opened", %{reviewer: account} do
      other = account_fixture()
      {:ok, _} = Friends.create_friendship(other.id, account.id)
      {:ok, mine} = Meetings.create_meeting(account, %{title: "Mine"})
      {:ok, theirs} = Meetings.create_meeting(other, %{title: "Friend's"})

      {:ok, _} =
        Meetings.update_permissions(theirs, %{
          permissions: %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
        })

      for meeting <- Meetings.list_meetings(account) do
        refute Meetings.level(meeting, account) == :lv3,
               "listed but cannot be opened: #{meeting.id}"
      end

      ids = Enum.map(Meetings.list_meetings(account), & &1.id)
      assert mine.id in ids
      assert theirs.id in ids
    end
  end
end
