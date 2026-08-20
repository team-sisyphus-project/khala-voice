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

  describe "인증" do
    test "비로그인은 401 JSON 을 받는다 (302 아님)" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/meetings")

      assert json_response(conn, 401)["code"] == "unauthorized"
    end
  end

  describe "회의 CRUD" do
    test "생성하면 Reviewer 역할로 돌아온다", %{conn: conn} do
      conn = post(conn, ~p"/api/meetings", %{"title" => "테스트 회의"})
      body = json_response(conn, 201)

      assert body["title"] == "테스트 회의"
      assert body["role"] == "reviewer"
      assert String.starts_with?(body["id"], "meet_")
    end

    test "내 회의 목록이 나온다", %{conn: conn, account: account} do
      {:ok, _} = Meetings.create_meeting(account, %{title: "내 회의"})

      body = conn |> get(~p"/api/meetings") |> json_response(200)

      assert length(body["meetings"]) == 1
      assert hd(body["meetings"])["title"] == "내 회의"
    end

    test "남의 회의는 404", %{conn: conn, other: other} do
      {:ok, meeting} = Meetings.create_meeting(other, %{title: "남의 회의"})

      conn = get(conn, ~p"/api/meetings/#{meeting.id}")
      assert json_response(conn, 404)["code"] == "not_found"
    end

    test "제목을 수정한다", %{conn: conn, account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "이전"})

      conn = patch(conn, ~p"/api/meetings/#{meeting.id}", %{"title" => "이후"})
      assert json_response(conn, 200)["title"] == "이후"
    end

    test "삭제된 회의는 404", %{conn: conn, account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      {:ok, _} = Meetings.delete_meeting(meeting)

      conn = get(conn, ~p"/api/meetings/#{meeting.id}")
      assert json_response(conn, 404)
    end
  end

  describe "Viewer 마스킹" do
    test "Viewer 에게는 audio_url 과 permissions 를 주지 않는다", %{
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
      # URL 도 그 URL 로 가는 링크도 주지 않는다. 저장 키가 결정적이라
      # 필드만 지우면 손으로 조립할 수 있다.
      refute Map.has_key?(hd(body["recording_sessions"]), "audio_url")
      refute Map.has_key?(hd(body["recording_sessions"]), "audio_href")
      refute Map.has_key?(body, "permissions")
    end

    test "Viewer 가 오디오 엔드포인트를 직접 부르면 404", %{conn: conn, account: account} do
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

      # 403 이 아니라 404 — 회의의 존재를 노출하지 않는다
      assert conn |> get(~p"/api/sessions/#{session.id}/audio") |> json_response(404)
    end

    test "Reviewer 는 오디오 링크를 받는다", %{conn: conn, account: account} do
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
      # 원본 URL 이 아니라 서명 발급 엔드포인트를 준다
      refute Map.has_key?(session, "audio_url")
      assert session["audio_href"] == "/api/sessions/#{session["id"]}/audio"
      assert body["permissions"]
    end
  end

  describe "녹음 세션" do
    setup %{account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      %{meeting: meeting}
    end

    test "세션을 만든다", %{conn: conn, meeting: meeting} do
      body = conn |> post(~p"/api/meetings/#{meeting.id}/sessions", %{}) |> json_response(201)

      assert body["status"] == "recording"
      assert body["session_index"] == 1
      assert body["started_at_unix"]
    end

    test "완료된 회의에는 세션을 못 만든다", %{conn: conn, meeting: meeting} do
      {:ok, _} = Meetings.set_status(meeting, "completed")

      conn = post(conn, ~p"/api/meetings/#{meeting.id}/sessions", %{})
      assert json_response(conn, 422)["code"] == "meeting_not_active"
    end

    test "허용하지 않는 MIME 은 거부한다", %{conn: conn, meeting: meeting} do
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

  describe "업로드 presign" do
    test "허용하지 않는 타입은 거부한다", %{conn: conn, account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      {:ok, session} = Meetings.create_session(meeting)

      conn =
        post(conn, ~p"/api/uploads/presign", %{
          "session_id" => session.id,
          "content_type" => "text/html"
        })

      assert json_response(conn, 422)["code"] == "unsupported_media_type"
    end

    test "남의 세션에는 presign 을 주지 않는다", %{conn: conn, other: other} do
      {:ok, meeting} = Meetings.create_meeting(other, %{})
      {:ok, session} = Meetings.create_session(meeting)

      conn =
        post(conn, ~p"/api/uploads/presign", %{
          "session_id" => session.id,
          "content_type" => "audio/webm"
        })

      assert json_response(conn, 404)
    end

    test "업로드가 끝난 세션에는 다시 발급하지 않는다", %{conn: conn, account: account} do
      # 같은 키로 다시 PUT 할 수 있으면 원본을 덮어쓸 수 있다
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

  describe "클라이언트가 준 audio_url 을 믿지 않는다" do
    setup %{account: account} do
      {:ok, meeting} = Meetings.create_meeting(account, %{})
      {:ok, session} = Meetings.create_session(meeting)
      %{meeting: meeting, session: with_storage_key(session)}
    end

    test "업로드 등록에 넣은 주소는 무시된다", %{conn: conn, session: session} do
      # 이 값이 그대로 저장되면 전사 워커가 사설망을 대신 GET 한다 (SSRF)
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

  describe "아카이브 잠금" do
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

    test "아카이브된 회의의 전사본은 고칠 수 없다", %{conn: conn, session: session} do
      conn =
        patch(conn, ~p"/api/sessions/#{session.id}/speakers", %{
          "speaker_map" => %{"speaker_1" => %{"name" => "바뀐 이름"}}
        })

      assert json_response(conn, 422)["code"] == "meeting_archived"
    end

    test "아카이브된 회의는 전사를 다시 돌릴 수 없다", %{conn: conn, session: session} do
      conn = post(conn, ~p"/api/sessions/#{session.id}/transcribe")
      assert json_response(conn, 422)["code"] == "meeting_archived"
    end
  end

  describe "공개 범위" do
    test "Contributor 는 공개 범위를 못 바꾼다 (404, 403 아님)", %{conn: conn, account: account} do
      other = account_fixture()
      {:ok, meeting} = Meetings.create_meeting(other, %{})
      {:ok, meeting} = Meetings.update_permissions(meeting, %{contributor_ids: [account.id]})

      # Contributor 로는 회의를 볼 수 있지만 권한 변경은 못 한다
      assert conn |> get(~p"/api/meetings/#{meeting.id}") |> json_response(200)

      assert conn
             |> patch(~p"/api/meetings/#{meeting.id}/permissions", %{
               "permissions" => %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
             })
             |> json_response(404)

      assert Meetings.get_meeting(meeting.id).permissions["view"]["mode"] != "all_friends"
    end

    test "Viewer 응답에는 permissions 키가 없다", %{conn: conn, account: account} do
      other = account_fixture()
      {:ok, _} = Friends.create_friendship(other.id, account.id)
      {:ok, meeting} = Meetings.create_meeting(other, %{})

      {:ok, _} =
        Meetings.update_permissions(meeting, %{
          permissions: %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
        })

      body = conn |> get(~p"/api/meetings/#{meeting.id}") |> json_response(200)

      # 프런트의 VisibilityPanel 이 이 키의 부재를 "lv0 이 아니다" 의 증거로 쓴다
      assert body["role"] == "viewer"
      refute Map.has_key?(body, "permissions")
    end

    test "selected_friends 로 지정하면 그 사람 목록에 나온다", %{conn: conn, account: account} do
      # camelCase 회귀. account_ids 로 저장하면 상세는 열리는데
      # list_meetings 의 '{view,accountIds}' fragment 에 안 걸려 목록에서 사라진다.
      viewer = account_fixture()
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "지정 공개"})

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

    test "모르는 모드는 저장 자체를 거부한다", %{conn: conn, account: account} do
      # 조용히 기본값으로 바꾸면 사용자는 자기가 고른 대로 됐다고 믿는다.
      # 저장 시점에 막고, 읽을 때(AccessLevel.normalize_view_scope)는 좁은 쪽으로 해석한다.
      {:ok, meeting} = Meetings.create_meeting(account, %{})

      conn =
        patch(conn, ~p"/api/meetings/#{meeting.id}/permissions", %{
          "permissions" => %{"view" => %{"mode" => "전체공개", "accountIds" => []}}
        })

      assert json_response(conn, 422)["code"] == "validation_failed"

      stranger = account_fixture()
      assert Meetings.level(Meetings.get_meeting(meeting.id), stranger) == :lv3
    end

    test "Reviewer 를 넘기면 넘긴 사람은 목록에서도 사라진다", %{conn: conn, account: account} do
      other = account_fixture()
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "양도"})

      body =
        conn
        |> patch(~p"/api/meetings/#{meeting.id}/permissions", %{
          "reviewer_id" => other.id,
          "contributor_ids" => []
        })
        |> json_response(200)

      # 응답의 role 이 이미 reviewer 가 아니다 — 프런트가 이걸 보고 화면을 뜬다
      refute body["role"] == "reviewer"
      refute Enum.any?(Meetings.list_meetings(account), &(&1.id == meeting.id))
      assert Enum.any?(Meetings.list_meetings(other), &(&1.id == meeting.id))
    end
  end
end
