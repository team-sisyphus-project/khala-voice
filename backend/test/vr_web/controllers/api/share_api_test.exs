defmodule VRWeb.API.ShareAPITest do
  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.{Accounts, Meetings}

  setup %{conn: conn} do
    owner = account_fixture()
    stranger = account_fixture()
    {:ok, token, _} = Accounts.create_session(owner)

    {:ok, meeting} = Meetings.create_meeting(owner, %{title: "공유 회의"})
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

  describe "Reviewer 링크 관리" do
    test "발급 응답에만 URL 과 PIN 이 있다", ctx do
      created = issue(ctx, %{"granted_role" => "viewer", "with_pincode" => true})

      assert created["url"] =~ "/share/slt_"
      assert created["pincode"] =~ ~r/^\d{6}$/
      assert created["has_pincode"] == true
      # 해시는 절대 안 나간다
      refute Map.has_key?(created, "token_hash")
      refute Map.has_key?(created, "pin_hash")

      listed =
        ctx.conn |> get(~p"/api/meetings/#{ctx.meeting.id}/share-links") |> json_response(200)

      link = hd(listed["share_links"])

      refute Map.has_key?(link, "url")
      refute Map.has_key?(link, "pincode")
      assert link["token_prefix"] =~ "slt_"
    end

    test "Reviewer 가 아니면 404", ctx do
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

    test "Contributor 도 링크를 발급할 수 없다", ctx do
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

    test "남의 링크는 id 를 알아도 못 건드린다", ctx do
      created = issue(ctx)
      {:ok, stranger_token, _} = Accounts.create_session(ctx.stranger)

      other =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{account_token: stranger_token})
        |> put_req_header("accept", "application/json")

      assert other |> delete(~p"/api/share-links/#{created["id"]}") |> json_response(404)
      assert other |> post(~p"/api/share-links/#{created["id"]}/rotate") |> json_response(404)
    end

    test "재발급하면 새 URL 이 나온다", ctx do
      created = issue(ctx)

      rotated =
        ctx.conn |> post(~p"/api/share-links/#{created["id"]}/rotate") |> json_response(200)

      assert rotated["url"] =~ "/share/slt_"
      assert rotated["token_prefix"] != created["token_prefix"]
    end

    test "폐기하면 204", ctx do
      created = issue(ctx)
      assert ctx.conn |> delete(~p"/api/share-links/#{created["id"]}") |> response(204)
    end
  end

  describe "게스트 진입" do
    test "들어가기 전에는 회의 내용을 주지 않는다", ctx do
      created = issue(ctx, %{"require_name" => true, "with_pincode" => true})
      token = created["url"] |> String.split("/share/") |> List.last()

      body = ctx.anon |> get(~p"/api/public/share/#{token}") |> json_response(200)

      assert body["require_name"] == true
      assert body["require_pincode"] == true
      assert body["granted_role"] == "viewer"
      # 제목조차 없다
      refute Map.has_key?(body, "title")
      refute Map.has_key?(body, "meeting_id")
    end

    test "입장하면 게스트 토큰을 받는다", ctx do
      created = issue(ctx, %{"require_name" => false})
      token = created["url"] |> String.split("/share/") |> List.last()

      body =
        ctx.anon
        |> post(~p"/api/public/share/#{token}/enter", %{})
        |> json_response(200)

      assert body["mode"] == "guest"
      assert String.starts_with?(body["guest_token"], "gst_")
    end

    test "PIN 이 틀리면 401", ctx do
      created = issue(ctx, %{"require_name" => false, "with_pincode" => true})
      token = created["url"] |> String.split("/share/") |> List.last()

      conn = post(ctx.anon, ~p"/api/public/share/#{token}/enter", %{"pincode" => "000000"})
      assert json_response(conn, 401)["code"] == "invalid_pincode"
    end

    test "없는 토큰은 404", ctx do
      assert ctx.anon |> get(~p"/api/public/share/slt_없음") |> json_response(404)
    end
  end

  describe "게스트가 보는 회의" do
    setup ctx do
      created = issue(ctx, %{"granted_role" => "viewer", "require_name" => false})
      token = created["url"] |> String.split("/share/") |> List.last()

      body = ctx.anon |> post(~p"/api/public/share/#{token}/enter", %{}) |> json_response(200)
      Map.put(ctx, :guest_token, body["guest_token"])
    end

    test "묶인 회의를 본다", ctx do
      body =
        ctx.anon
        |> guest_conn(ctx.guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      assert body["id"] == ctx.meeting.id
      assert body["role"] == "viewer"
    end

    test "참여자 계정 id 는 주지 않는다", ctx do
      body =
        ctx.anon
        |> guest_conn(ctx.guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      # 사람 목록이 새어 나가지 않게 한다
      refute Map.has_key?(body, "owner_id")
      refute Map.has_key?(body, "reviewer_id")
      refute Map.has_key?(body, "contributor_ids")
      refute Map.has_key?(body, "permissions")
    end

    test "게스트 토큰 없이는 401", ctx do
      conn = get(ctx.anon, ~p"/api/public/guest/meeting")
      assert json_response(conn, 401)["code"] == "guest_session_required"
    end

    test "게스트 토큰으로 일반 API 는 못 쓴다", ctx do
      # 게스트 토큰은 /api/public 밖에서 아무 의미가 없다
      conn =
        ctx.anon
        |> guest_conn(ctx.guest_token)
        |> get(~p"/api/meetings/#{ctx.meeting.id}")

      assert json_response(conn, 401)
    end

    test "게스트에게 전사 · 요약 · 업로드 경로가 없다", _ctx do
      # 라우터에 아예 없다. 크레딧을 태울 경로를 링크에 딸려 보내지 않는다.
      routes = VRWeb.Router.__routes__() |> Enum.map(& &1.path)
      guest_routes = Enum.filter(routes, &String.starts_with?(&1, "/api/public"))

      refute Enum.any?(guest_routes, &String.contains?(&1, "transcribe"))
      refute Enum.any?(guest_routes, &String.contains?(&1, "summarize"))
      refute Enum.any?(guest_routes, &String.contains?(&1, "upload"))
      refute Enum.any?(guest_routes, &String.contains?(&1, "presign"))
    end

    test "링크를 폐기하면 즉시 끊긴다", ctx do
      created =
        ctx.conn |> get(~p"/api/meetings/#{ctx.meeting.id}/share-links") |> json_response(200)

      link_id = created["share_links"] |> hd() |> Map.get("id")
      assert ctx.conn |> delete(~p"/api/share-links/#{link_id}") |> response(204)

      conn = ctx.anon |> guest_conn(ctx.guest_token) |> get(~p"/api/public/guest/meeting")
      assert json_response(conn, 401)
    end

    test "나가면 세션이 죽는다", ctx do
      assert ctx.anon
             |> guest_conn(ctx.guest_token)
             |> delete(~p"/api/public/guest/session")
             |> response(204)

      conn = ctx.anon |> guest_conn(ctx.guest_token) |> get(~p"/api/public/guest/meeting")
      assert json_response(conn, 401)
    end
  end

  describe "게스트에게 새면 안 되는 것" do
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
              %{"speaker" => "speaker_1", "text" => "말", "start_ms" => 0, "end_ms" => 3000}
            ]
          },
          speaker_map: %{"speaker_1" => %{"name" => "김철수", "account_id" => ctx.owner.id}}
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

    test "화자 매핑의 계정 id 가 나가지 않는다", ctx do
      # 전사만 넘겨도 참여자 계정 id 가 통째로 새어 나가기 쉬운 자리다
      guest_token = enter_guest(ctx, %{"granted_role" => "viewer", "require_name" => false})

      body =
        ctx.anon
        |> guest_conn(guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      speaker_map = hd(body["recording_sessions"])["speaker_map"]

      assert speaker_map["speaker_1"]["name"] == "김철수"
      refute Map.has_key?(speaker_map["speaker_1"], "account_id")
      refute json_string(body) =~ ctx.owner.id
    end

    test "요약 실패 원문과 과금액이 나가지 않는다", ctx do
      {:ok, _} =
        Meetings.update_summary(ctx.meeting, %{
          last_summary_error: %{"reason" => "내부 예외 상세", "at" => "2026-01-01T00:00:00Z"}
        })

      guest_token = enter_guest(ctx, %{"granted_role" => "viewer", "require_name" => false})

      body =
        ctx.anon
        |> guest_conn(guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      refute json_string(body) =~ "내부 예외 상세"
      refute Map.has_key?(body, "total_credits_charged")
      refute Map.has_key?(hd(body["recording_sessions"]), "credits_charged")
    end

    test "Viewer 게스트는 오디오 경로 자체가 없고 직접 불러도 404", ctx do
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

    test "Contributor 게스트는 게스트 전용 오디오 경로를 받는다", ctx do
      guest_token = enter_guest(ctx, %{"granted_role" => "contributor", "require_name" => false})

      body =
        ctx.anon
        |> guest_conn(guest_token)
        |> get(~p"/api/public/guest/meeting")
        |> json_response(200)

      href = hd(body["recording_sessions"])["audio_href"]

      # 계정 전용 경로를 주면 눌러도 401 만 난다
      assert href == "/api/public/guest/sessions/#{ctx.session.id}/audio"
    end

    test "다른 회의의 세션 오디오는 게스트에게 404", ctx do
      guest_token = enter_guest(ctx, %{"granted_role" => "contributor", "require_name" => false})

      other_owner = account_fixture()
      {:ok, other} = Meetings.create_meeting(other_owner, %{title: "남의 회의"})
      {:ok, other_session} = Meetings.create_session(other)

      assert ctx.anon
             |> guest_conn(guest_token)
             |> get(~p"/api/public/guest/sessions/#{other_session.id}/audio")
             |> json_response(404)
    end
  end

  defp json_string(value), do: Jason.encode!(value)
end
