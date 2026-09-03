defmodule VRWeb.API.MeetingAPITest do
  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.{Accounts, Friends, Meetings}

  setup %{conn: conn} do
    account = account_fixture()
    other = account_fixture()
    {:ok, token, _} = Accounts.create_session(account)

    conn =
      conn
      |> Plug.Test.init_test_session(%{account_token: token})
      |> put_req_header("accept", "application/json")

    %{conn: conn, account: account, other: other}
  end

  describe "authentication" do
    test "unauthenticated gets 401 JSON (not 302)" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/meetings")

      assert json_response(conn, 401)["code"] == "unauthorized"
    end
  end

  describe "meeting CRUD" do
    test "creating returns the Reviewer role", %{conn: conn} do
      conn = post(conn, ~p"/api/meetings", %{"title" => "Test Meeting"})
      body = json_response(conn, 201)

      assert body["title"] == "Test Meeting"
      assert body["role"] == "reviewer"
      assert String.starts_with?(body["id"], "meet_")
    end

    test "lists my meetings", %{conn: conn, account: account} do
      {:ok, _} = Meetings.create_meeting(account, %{title: "My Meeting"})

      body = conn |> get(~p"/api/meetings") |> json_response(200)

      assert length(body["meetings"]) == 1
      assert hd(body["meetings"])["title"] == "My Meeting"
    end

    test "someone else's meeting is 404", %{conn: conn, other: other} do
      {:ok, meeting} = Meetings.create_meeting(other, %{title: "Someone Else's Meeting"})

      conn = get(conn, ~p"/api/meetings/#{meeting.id}")
      assert json_response(conn, 404)["code"] == "not_found"
    end

    test "edits the title", %{conn: conn, account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "Before"})

      conn = patch(conn, ~p"/api/meetings/#{meeting.id}", %{"title" => "After"})
      assert json_response(conn, 200)["title"] == "After"
    end

    test "a deleted meeting is 404", %{conn: conn, account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      {:ok, _} = Meetings.delete_meeting(meeting)

      conn = get(conn, ~p"/api/meetings/#{meeting.id}")
      assert json_response(conn, 404)
    end
  end

  describe "Viewer masking" do
    test "Viewers get neither audio_url nor permissions", %{
      conn: conn,
      account: account,
      other: other
    } do
      {:ok, _} = Friends.create_friendship(other.id, account.id)
      {:ok, meeting} = Meetings.create_meeting(other, %{})

      {:ok, meeting} =
        Meetings.update_permissions(meeting, %{
          permissions: %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
        })

      {:ok, session} = Meetings.create_session(meeting)

      {:ok, _} =
        Meetings.register_upload(with_storage_key(session), %{
          duration_seconds: 60,
          file_size_bytes: 1000,
          mime_type: "audio/webm"
        })

      body = conn |> get(~p"/api/meetings/#{meeting.id}") |> json_response(200)

      assert body["role"] == "viewer"
      # Neither the URL nor a link to it is provided. Storage keys are deterministic,
      # so merely dropping the field would let it be assembled by hand.
      refute Map.has_key?(hd(body["recording_sessions"]), "audio_url")
      refute Map.has_key?(hd(body["recording_sessions"]), "audio_href")
      refute Map.has_key?(body, "permissions")
    end

    test "a Viewer calling the audio endpoint directly gets 404", %{conn: conn, account: account} do
      other = account_fixture()
      {:ok, _} = Friends.create_friendship(other.id, account.id)
      {:ok, meeting} = Meetings.create_meeting(other, %{})

      {:ok, meeting} =
        Meetings.update_permissions(meeting, %{
          permissions: %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
        })

      {:ok, session} = Meetings.create_session(meeting)

      {:ok, session} =
        Meetings.register_upload(with_storage_key(session), %{
          duration_seconds: 60,
          file_size_bytes: 1000,
          mime_type: "audio/webm"
        })

      # 404, not 403 — do not reveal the meeting exists
      assert conn |> get(~p"/api/sessions/#{session.id}/audio") |> json_response(404)
    end

    test "the Reviewer receives the audio link", %{conn: conn, account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      {:ok, session} = Meetings.create_session(meeting)

      {:ok, _} =
        Meetings.register_upload(with_storage_key(session), %{
          duration_seconds: 60,
          file_size_bytes: 1000,
          mime_type: "audio/webm"
        })

      body = conn |> get(~p"/api/meetings/#{meeting.id}") |> json_response(200)

      session = hd(body["recording_sessions"])
      # Provides the signing endpoint, not the raw URL
      refute Map.has_key?(session, "audio_url")
      assert session["audio_href"] == "/api/sessions/#{session["id"]}/audio"
      assert body["permissions"]
    end
  end

  describe "recording sessions" do
    setup %{account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      %{meeting: meeting}
    end

    test "creates a session", %{conn: conn, meeting: meeting} do
      body = conn |> post(~p"/api/meetings/#{meeting.id}/sessions", %{}) |> json_response(201)

      assert body["status"] == "recording"
      assert body["session_index"] == 1
      assert body["started_at_unix"]
    end

    test "cannot create sessions on a completed meeting", %{conn: conn, meeting: meeting} do
      {:ok, _} = Meetings.set_status(meeting, "completed")

      conn = post(conn, ~p"/api/meetings/#{meeting.id}/sessions", %{})
      assert json_response(conn, 422)["code"] == "meeting_not_active"
    end

    test "rejects disallowed MIME types", %{conn: conn, meeting: meeting} do
      {:ok, session} = Meetings.create_session(meeting)

      conn =
        post(conn, ~p"/api/sessions/#{session.id}/upload", %{
          "audio_url" => "https://cdn.test/a.exe",
          "duration_seconds" => 10,
          "file_size_bytes" => 100,
          "mime_type" => "application/x-msdownload"
        })

      assert json_response(conn, 422)["code"] == "unsupported_media_type"
    end
  end

  describe "upload presign" do
    test "rejects disallowed types", %{conn: conn, account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      {:ok, session} = Meetings.create_session(meeting)

      conn =
        post(conn, ~p"/api/uploads/presign", %{
          "session_id" => session.id,
          "content_type" => "text/html"
        })

      assert json_response(conn, 422)["code"] == "unsupported_media_type"
    end

    test "no presign for someone else's session", %{conn: conn, other: other} do
      {:ok, meeting} = Meetings.create_meeting(other, %{})
      {:ok, session} = Meetings.create_session(meeting)

      conn =
        post(conn, ~p"/api/uploads/presign", %{
          "session_id" => session.id,
          "content_type" => "audio/webm"
        })

      assert json_response(conn, 404)
    end

    test "no re-issue for a session already uploaded", %{conn: conn, account: account} do
      # Being able to PUT the same key again would allow overwriting the original
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      {:ok, session} = Meetings.create_session(meeting)

      {:ok, session} =
        Meetings.register_upload(with_storage_key(session), %{
          duration_seconds: 10,
          file_size_bytes: 100,
          mime_type: "audio/webm"
        })

      conn =
        post(conn, ~p"/api/uploads/presign", %{
          "session_id" => session.id,
          "content_type" => "audio/webm"
        })

      assert json_response(conn, 422)["code"] == "already_uploaded"
    end
  end

  describe "client-supplied audio_url is not trusted" do
    setup %{account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      {:ok, session} = Meetings.create_session(meeting)
      %{meeting: meeting, session: with_storage_key(session)}
    end

    test "an address sent with upload registration is ignored", %{conn: conn, session: session} do
      # If stored verbatim, the transcription worker would GET the private network on our behalf (SSRF)
      conn =
        post(conn, ~p"/api/sessions/#{session.id}/upload", %{
          "audio_url" => "http://169.254.169.254/latest/meta-data/",
          "duration_seconds" => 30,
          "file_size_bytes" => 1000,
          "mime_type" => "audio/webm"
        })

      assert json_response(conn, 200)

      stored = Meetings.get_session(session.id)
      refute stored.audio_url =~ "169.254"
      assert stored.audio_url =~ stored.storage_key
    end
  end

  describe "archive lock" do
    setup %{account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      {:ok, session} = Meetings.create_session(meeting)

      {:ok, session} =
        Meetings.register_upload(with_storage_key(session), %{
          duration_seconds: 30,
          file_size_bytes: 1000,
          mime_type: "audio/webm"
        })

      {:ok, meeting} = Meetings.set_status(meeting, "archived")
      %{meeting: meeting, session: session}
    end

    test "an archived meeting's transcript cannot be edited", %{conn: conn, session: session} do
      conn =
        patch(conn, ~p"/api/sessions/#{session.id}/speakers", %{
          "speaker_map" => %{"speaker_1" => %{"name" => "Changed Name"}}
        })

      assert json_response(conn, 422)["code"] == "meeting_archived"
    end

    test "an archived meeting cannot be re-transcribed", %{conn: conn, session: session} do
      conn = post(conn, ~p"/api/sessions/#{session.id}/transcribe")
      assert json_response(conn, 422)["code"] == "meeting_archived"
    end
  end

  describe "visibility scope" do
    test "a Contributor cannot change visibility (404, not 403)", %{conn: conn, account: account} do
      other = account_fixture()
      {:ok, meeting} = Meetings.create_meeting(other, %{})
      {:ok, meeting} = Meetings.update_permissions(meeting, %{contributor_ids: [account.id]})

      # A Contributor can view the meeting but not change permissions
      assert conn |> get(~p"/api/meetings/#{meeting.id}") |> json_response(200)

      assert conn
             |> patch(~p"/api/meetings/#{meeting.id}/permissions", %{
               "permissions" => %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
             })
             |> json_response(404)

      assert Meetings.get_meeting(meeting.id).permissions["view"]["mode"] != "all_friends"
    end

    test "the Viewer response carries no permissions key", %{conn: conn, account: account} do
      other = account_fixture()
      {:ok, _} = Friends.create_friendship(other.id, account.id)
      {:ok, meeting} = Meetings.create_meeting(other, %{})

      {:ok, _} =
        Meetings.update_permissions(meeting, %{
          permissions: %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
        })

      body = conn |> get(~p"/api/meetings/#{meeting.id}") |> json_response(200)

      # The frontend VisibilityPanel uses this key's absence as evidence of "not lv0"
      assert body["role"] == "viewer"
      refute Map.has_key?(body, "permissions")
    end

    test "selected_friends puts it in that person's list", %{conn: conn, account: account} do
      # camelCase regression. Stored as account_ids, the detail view opens but
      # list_meetings' '{view,accountIds}' fragment misses it, so it vanishes from the list.
      viewer = account_fixture()
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "Selective Visibility"})

      assert conn
             |> patch(~p"/api/meetings/#{meeting.id}/permissions", %{
               "permissions" => %{
                 "view" => %{"mode" => "selected_friends", "accountIds" => [viewer.id]}
               }
             })
             |> json_response(200)

      assert Meetings.level(Meetings.get_meeting(meeting.id), viewer) == :lv2
      assert Enum.any?(Meetings.list_meetings(viewer), &(&1.id == meeting.id))
    end

    test "an unknown mode is rejected at save time", %{conn: conn, account: account} do
      # Silently falling back to the default would leave users believing their choice took effect.
      # Block at save time; at read time (AccessLevel.normalize_view_scope) interpret narrowly.
      {:ok, meeting} = Meetings.create_meeting(account, %{})

      conn =
        patch(conn, ~p"/api/meetings/#{meeting.id}/permissions", %{
          "permissions" => %{"view" => %{"mode" => "public_to_all", "accountIds" => []}}
        })

      assert json_response(conn, 422)["code"] == "validation_failed"

      stranger = account_fixture()
      assert Meetings.level(Meetings.get_meeting(meeting.id), stranger) == :lv3
    end

    test "handing off the Reviewer removes the giver from the list too", %{conn: conn, account: account} do
      other = account_fixture()
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "Handoff"})

      body =
        conn
        |> patch(~p"/api/meetings/#{meeting.id}/permissions", %{
          "reviewer_id" => other.id,
          "contributor_ids" => []
        })
        |> json_response(200)

      # The response role is already not reviewer — the frontend leaves the screen based on this
      refute body["role"] == "reviewer"
      refute Enum.any?(Meetings.list_meetings(account), &(&1.id == meeting.id))
      assert Enum.any?(Meetings.list_meetings(other), &(&1.id == meeting.id))
    end
  end
end
