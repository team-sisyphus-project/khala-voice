defmodule VRWeb.API.ShareAPITest do
  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.{Accounts, Meetings}

  setup %{conn: conn} do
    owner = account_fixture()
    stranger = account_fixture()
    {:ok, token, _} = Accounts.create_session(owner)

    {:ok, meeting} = Meetings.create_meeting(owner, %{title: "Shared Meeting"})
    {:ok, meeting} = Meetings.update_permissions(meeting, %{guest_link_enabled: true})

    authed =
      conn
      |> Plug.Test.init_test_session(%{account_token: token})
      |> put_req_header("accept", "application/json")

    anon =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> put_req_header("accept", "application/json")

    %{conn: authed, anon: anon, owner: owner, stranger: stranger, meeting: meeting}
  end

  defp issue(ctx, attrs \\ %{}) do
    ctx.conn
    |> post(~p"/api/meetings/#{ctx.meeting.id}/share-links", attrs)
    |> json_response(201)
  end

  defp guest_conn(anon, token), do: put_req_header(anon, "x-guest-token", token)

  describe "Reviewer link management" do
    test "URL and PIN exist only in the issue response", ctx do
      created = issue(ctx, %{"granted_role" => "viewer", "with_pincode" => true})

      assert created["url"] =~ "/share/slt_"
      assert created["pincode"] =~ ~r/^\d{6}$/
      assert created["has_pincode"] == true
      # Hashes never leave
      refute Map.has_key?(created, "token_hash")
      refute Map.has_key?(created, "pin_hash")

      listed =
        ctx.conn |> get(~p"/api/meetings/#{ctx.meeting.id}/share-links") |> json_response(200)

      link = hd(listed["share_links"])

      refute Map.has_key?(link, "url")
      refute Map.has_key?(link, "pincode")
      assert link["token_prefix"] =~ "slt_"
    end

    test "non-Reviewers get 404", ctx do
      {:ok, stranger_token, _} = Accounts.create_session(ctx.stranger)

      other =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{account_token: stranger_token})
        |> put_req_header("accept", "application/json")

      assert other |> get(~p"/api/meetings/#{ctx.meeting.id}/share-links") |> json_response(404)

      assert other
             |> post(~p"/api/meetings/#{ctx.meeting.id}/share-links", %{})
             |> json_response(404)
    end

    test "even a Contributor cannot issue links", ctx do
      contributor = account_fixture()
      {:ok, _} = Meetings.update_permissions(ctx.meeting, %{contributor_ids: [contributor.id]})
      {:ok, token, _} = Accounts.create_session(contributor)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{account_token: token})
        |> put_req_header("accept", "application/json")

      assert conn
             |> post(~p"/api/meetings/#{ctx.meeting.id}/share-links", %{})
             |> json_response(404)
    end

    test "someone else's link cannot be touched even knowing its id", ctx do
      created = issue(ctx)
      {:ok, stranger_token, _} = Accounts.create_session(ctx.stranger)

      other =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{account_token: stranger_token})
        |> put_req_header("accept", "application/json")

      assert other |> delete(~p"/api/share-links/#{created["id"]}") |> json_response(404)
      assert other |> post(~p"/api/share-links/#{created["id"]}/rotate") |> json_response(404)
    end

    test "rotation yields a new URL", ctx do
      created = issue(ctx)

      rotated =
        ctx.conn |> post(~p"/api/share-links/#{created["id"]}/rotate") |> json_response(200)

      assert rotated["url"] =~ "/share/slt_"
      assert rotated["token_prefix"] != created["token_prefix"]
    end

    test "revoking returns 204", ctx do
      created = issue(ctx)
      assert ctx.conn |> delete(~p"/api/share-links/#{created["id"]}") |> response(204)
    end
  end

  describe "guest entry" do
    test "no meeting content before entering", ctx do
      created = issue(ctx, %{"require_name" => true, "with_pincode" => true})
      token = created["url"] |> String.split("/share/") |> List.last()

      body = ctx.anon |> get(~p"/api/public/share/#{token}") |> json_response(200)

      assert body["require_name"] == true
      assert body["require_pincode"] == true
      assert body["granted_role"] == "viewer"
      # Not even the title
      refute Map.has_key?(body, "title")
      refute Map.has_key?(body, "meeting_id")
    end

    test "entering yields a guest token", ctx do
      created = issue(ctx, %{"require_name" => false})
      token = created["url"] |> String.split("/share/") |> List.last()

      body =
        ctx.anon
        |> post(~p"/api/public/share/#{token}/enter", %{})
        |> json_response(200)

      assert body["mode"] == "guest"
      assert String.starts_with?(body["guest_token"], "gst_")
    end

    test "a wrong PIN is 401", ctx do
      created = issue(ctx, %{"require_name" => false, "with_pincode" => true})
      token = created["url"] |> String.split("/share/") |> List.last()

      conn = post(ctx.anon, ~p"/api/public/share/#{token}/enter", %{"pincode" => "000000"})
      assert json_response(conn, 401)["code"] == "invalid_pincode"
    end

    test "an unknown token is 404", ctx do
      assert ctx.anon |> get(~p"/api/public/share/slt_missing") |> json_response(404)
    end
  end

  describe "the meeting as guests see it" do
    setup ctx do
      created = issue(ctx, %{"granted_role" => "viewer", "require_name" => false})
      token = created["url"] |> String.split("/share/") |> List.last()

      body = ctx.anon |> post(~p"/api/public/share/#{token}/enter", %{}) |> json_response(200)
      Map.put(ctx, :guest_token, body["guest_token"])
    end

    test "sees the bound meeting", ctx do
      body =
        ctx.anon
        |> guest_conn(ctx.guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      assert body["id"] == ctx.meeting.id
      assert body["role"] == "viewer"
    end

    test "participant account ids are not provided", ctx do
      body =
        ctx.anon
        |> guest_conn(ctx.guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      # Keeps the people list from leaking
      refute Map.has_key?(body, "owner_id")
      refute Map.has_key?(body, "reviewer_id")
      refute Map.has_key?(body, "contributor_ids")
      refute Map.has_key?(body, "permissions")
    end

    test "401 without a guest token", ctx do
      conn = get(ctx.anon, ~p"/api/public/guest/meeting")
      assert json_response(conn, 401)["code"] == "guest_session_required"
    end

    test "a guest token cannot use the regular API", ctx do
      # Guest tokens mean nothing outside /api/public
      conn =
        ctx.anon
        |> guest_conn(ctx.guest_token)
        |> get(~p"/api/meetings/#{ctx.meeting.id}")

      assert json_response(conn, 401)
    end

    test "guests have no transcription, summary, or upload routes", _ctx do
      # Absent from the router entirely. Do not ship credit-burning routes along with a link.
      routes = VRWeb.Router.__routes__() |> Enum.map(& &1.path)
      guest_routes = Enum.filter(routes, &String.starts_with?(&1, "/api/public"))

      refute Enum.any?(guest_routes, &String.contains?(&1, "transcribe"))
      refute Enum.any?(guest_routes, &String.contains?(&1, "summarize"))
      refute Enum.any?(guest_routes, &String.contains?(&1, "upload"))
      refute Enum.any?(guest_routes, &String.contains?(&1, "presign"))
    end

    test "revoking the link disconnects immediately", ctx do
      created =
        ctx.conn |> get(~p"/api/meetings/#{ctx.meeting.id}/share-links") |> json_response(200)

      link_id = created["share_links"] |> hd() |> Map.get("id")
      assert ctx.conn |> delete(~p"/api/share-links/#{link_id}") |> response(204)

      conn = ctx.anon |> guest_conn(ctx.guest_token) |> get(~p"/api/public/guest/meeting")
      assert json_response(conn, 401)
    end

    test "leaving kills the session", ctx do
      assert ctx.anon
             |> guest_conn(ctx.guest_token)
             |> delete(~p"/api/public/guest/session")
             |> response(204)

      conn = ctx.anon |> guest_conn(ctx.guest_token) |> get(~p"/api/public/guest/meeting")
      assert json_response(conn, 401)
    end
  end

  describe "what must not leak to guests" do
    setup ctx do
      {:ok, session} = Meetings.create_session(ctx.meeting)

      key =
        VR.Storage.recording_key(ctx.meeting.id, session.id, session.started_at_unix, "webm")

      {:ok, session} = Meetings.set_storage_key(session, key)

      {:ok, session} =
        Meetings.register_upload(session, %{
          duration_seconds: 30,
          file_size_bytes: 1000,
          mime_type: "audio/webm"
        })

      {:ok, _} =
        Meetings.update_transcript(session, %{
          transcript: %{
            "segments" => [
              %{"speaker" => "speaker_1", "text" => "words", "start_ms" => 0, "end_ms" => 3000}
            ]
          },
          speaker_map: %{"speaker_1" => %{"name" => "John Doe", "account_id" => ctx.owner.id}}
        })

      %{session: session}
    end

    defp enter_guest(ctx, attrs) do
      created =
        ctx.conn
        |> post(~p"/api/meetings/#{ctx.meeting.id}/share-links", attrs)
        |> json_response(201)

      token = created["url"] |> String.split("/share/") |> List.last()

      body = ctx.anon |> post(~p"/api/public/share/#{token}/enter", %{}) |> json_response(200)
      body["guest_token"]
    end

    test "account ids in the speaker map do not leave", ctx do
      # Even just handing over the transcript is where participant account ids leak wholesale
      guest_token = enter_guest(ctx, %{"granted_role" => "viewer", "require_name" => false})

      body =
        ctx.anon
        |> guest_conn(guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      speaker_map = hd(body["recording_sessions"])["speaker_map"]

      assert speaker_map["speaker_1"]["name"] == "John Doe"
      refute Map.has_key?(speaker_map["speaker_1"], "account_id")
      refute json_string(body) =~ ctx.owner.id
    end

    test "raw summary-failure details and billing amounts do not leave", ctx do
      {:ok, _} =
        Meetings.update_summary(ctx.meeting, %{
          last_summary_error: %{"reason" => "internal exception details", "at" => "2026-01-01T00:00:00Z"}
        })

      guest_token = enter_guest(ctx, %{"granted_role" => "viewer", "require_name" => false})

      body =
        ctx.anon
        |> guest_conn(guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      refute json_string(body) =~ "internal exception details"
      refute Map.has_key?(body, "total_credits_charged")
      refute Map.has_key?(hd(body["recording_sessions"]), "credits_charged")
    end

    test "Viewer guests have no audio path at all, and calling directly is 404", ctx do
      guest_token = enter_guest(ctx, %{"granted_role" => "viewer", "require_name" => false})

      body =
        ctx.anon
        |> guest_conn(guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      refute Map.has_key?(hd(body["recording_sessions"]), "audio_href")

      assert ctx.anon
             |> guest_conn(guest_token)
             |> get(~p"/api/public/guest/sessions/#{ctx.session.id}/audio")
             |> json_response(404)
    end

    test "Contributor guests receive the guest-only audio path", ctx do
      guest_token = enter_guest(ctx, %{"granted_role" => "contributor", "require_name" => false})

      body =
        ctx.anon
        |> guest_conn(guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      href = hd(body["recording_sessions"])["audio_href"]

      # Handing them the account-only path would just 401 on click
      assert href == "/api/public/guest/sessions/#{ctx.session.id}/audio"
    end

    test "another meeting's session audio is 404 for guests", ctx do
      guest_token = enter_guest(ctx, %{"granted_role" => "contributor", "require_name" => false})

      other_owner = account_fixture()
      {:ok, other} = Meetings.create_meeting(other_owner, %{title: "Someone Else's Meeting"})
      {:ok, other_session} = Meetings.create_session(other)

      assert ctx.anon
             |> guest_conn(guest_token)
             |> get(~p"/api/public/guest/sessions/#{other_session.id}/audio")
             |> json_response(404)
    end
  end

  defp json_string(value), do: Jason.encode!(value)
end
