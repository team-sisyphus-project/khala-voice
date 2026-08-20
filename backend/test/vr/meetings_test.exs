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
    {:ok, meeting} = Meetings.create_meeting(reviewer, %{title: "주간 회의"})

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

  describe "생성" do
    test "만든 사람이 Reviewer가 된다", %{reviewer: reviewer} do
      {:ok, m} = Meetings.create_meeting(reviewer, %{})
      assert m.owner_id == reviewer.id
      assert m.reviewer_id == reviewer.id
      assert m.status == "active"
      assert String.starts_with?(m.id, "meet_")
    end

    test "제목을 안 주면 날짜로 채운다", %{reviewer: reviewer} do
      {:ok, m} = Meetings.create_meeting(reviewer, %{})
      assert m.title =~ "회의"
    end

    test "기본 공개 범위는 관계자만이다", %{reviewer: reviewer} do
      {:ok, m} = Meetings.create_meeting(reviewer, %{})
      assert get_in(m.permissions, ["view", "mode"]) == "assignees_only"
    end
  end

  describe "권한 (Reviewer / Contributor / Viewer)" do
    test "Reviewer 는 lv0", ctx do
      assert Meetings.level(ctx.meeting, ctx.reviewer) == :lv0
    end

    test "Contributor 는 lv1", ctx do
      assert Meetings.level(ctx.meeting, ctx.contributor) == :lv1
    end

    test "관계자만 범위에서는 친구도 못 본다", ctx do
      assert Meetings.level(ctx.meeting, ctx.friend) == :lv3
    end

    test "전체 친구 공개로 바꾸면 친구는 Viewer가 된다", ctx do
      {:ok, m} =
        Meetings.update_permissions(ctx.meeting, %{
          permissions: %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
        })

      assert Meetings.level(m, ctx.friend) == :lv2
      # 친구가 아닌 사람은 여전히 접근 불가
      assert Meetings.level(m, ctx.stranger) == :lv3
    end

    test "선택한 친구만 범위", ctx do
      {:ok, m} =
        Meetings.update_permissions(ctx.meeting, %{
          permissions: %{
            "view" => %{"mode" => "selected_friends", "accountIds" => [ctx.friend.id]}
          }
        })

      assert Meetings.level(m, ctx.friend) == :lv2
      assert Meetings.level(m, ctx.stranger) == :lv3
    end

    test "나만 범위에서는 Contributor 도 여전히 lv1", ctx do
      {:ok, m} =
        Meetings.update_permissions(ctx.meeting, %{
          permissions: %{"view" => %{"mode" => "me_only", "accountIds" => []}}
        })

      assert Meetings.level(m, ctx.reviewer) == :lv0
      assert Meetings.level(m, ctx.contributor) == :lv1
      assert Meetings.level(m, ctx.friend) == :lv3
    end

    test "어드민은 항상 lv0", ctx do
      admin = account_fixture()
      admin = %{admin | is_admin: true}
      assert Meetings.level(ctx.meeting, admin) == :lv0
    end

    test "게스트는 링크가 준 역할을 갖는다", ctx do
      bound = [guest_resource_id: ctx.meeting.id]

      assert Meetings.level(ctx.meeting, nil, [guest_role: "viewer"] ++ bound) == :lv2
      assert Meetings.level(ctx.meeting, nil, [guest_role: "contributor"] ++ bound) == :lv1
      assert Meetings.level(ctx.meeting, nil) == :lv3
    end

    test "게스트 역할은 묶인 회의에서만 유효하다", ctx do
      # 게스트 토큰 하나로 다른 회의가 열리면 안 된다.
      # 정상 경로는 VR.Sharing.guest_authorize/2 가 막지만, 호출부를 하나
      # 빠뜨렸을 때도 닫히는 쪽으로 실패해야 한다.
      assert Meetings.level(ctx.meeting, nil, guest_role: "contributor") == :lv3

      assert Meetings.level(ctx.meeting, nil,
               guest_role: "contributor",
               guest_resource_id: "meet_다른회의"
             ) == :lv3
    end

    test "게스트에게 reviewer 를 줄 수는 없다", ctx do
      # 링크 하나로 삭제 권한까지 넘어가지 않는다
      assert Meetings.level(ctx.meeting, nil,
               guest_role: "reviewer",
               guest_resource_id: ctx.meeting.id
             ) == :lv3
    end
  end

  describe "authorize/4" do
    test "권한이 모자라면 not_found (403이 아니다)", ctx do
      assert {:error, :not_found} = Meetings.authorize(ctx.meeting.id, ctx.stranger, :lv2)
    end

    test "없는 회의도 not_found", ctx do
      assert {:error, :not_found} = Meetings.authorize("meet_nope", ctx.reviewer, :lv2)
    end

    test "충분하면 회의와 레벨을 준다", ctx do
      assert {:ok, m, :lv1} = Meetings.authorize(ctx.meeting.id, ctx.contributor, :lv1)
      assert m.id == ctx.meeting.id
    end

    test "Contributor 는 lv0 을 요구하는 작업을 못 한다", ctx do
      assert {:error, :not_found} = Meetings.authorize(ctx.meeting.id, ctx.contributor, :lv0)
    end
  end

  describe "목록" do
    test "Reviewer 는 자기 회의를 본다", ctx do
      ids = Meetings.list_meetings(ctx.reviewer) |> Enum.map(& &1.id)
      assert ctx.meeting.id in ids
    end

    test "Contributor 도 본다", ctx do
      ids = Meetings.list_meetings(ctx.contributor) |> Enum.map(& &1.id)
      assert ctx.meeting.id in ids
    end

    test "관계없는 사람은 못 본다", ctx do
      assert Meetings.list_meetings(ctx.stranger) == []
    end

    test "전체 친구 공개면 친구도 목록에 나온다", ctx do
      {:ok, _} =
        Meetings.update_permissions(ctx.meeting, %{
          permissions: %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
        })

      ids = Meetings.list_meetings(ctx.friend) |> Enum.map(& &1.id)
      assert ctx.meeting.id in ids
    end

    test "아카이브는 기본으로 숨긴다", ctx do
      {:ok, _} = Meetings.set_status(ctx.meeting, "archived")
      assert Meetings.list_meetings(ctx.reviewer) == []
      assert [_] = Meetings.list_meetings(ctx.reviewer, status: "archived")
    end

    test "토픽·기간·검색어로 거른다", ctx do
      assert [_] = Meetings.list_meetings(ctx.reviewer, q: "주간")
      assert [] = Meetings.list_meetings(ctx.reviewer, q: "없는단어")
    end
  end

  describe "녹음 세션" do
    test "번호가 1부터 이어진다", ctx do
      {:ok, s1} = Meetings.create_session(ctx.meeting)
      {:ok, s2} = Meetings.create_session(ctx.meeting)
      assert s1.session_index == 1
      assert s2.session_index == 2
      assert String.starts_with?(s1.id, "mrss_")
    end

    test "전사가 남은 세션이 있으면 pending 이다", ctx do
      # 긴 회의는 20분마다 쪼개져 청크가 여럿이 되고 몇 분씩 시차를 두고 끝난다.
      # 하나라도 남아 있으면 자동 요약을 시작하면 안 된다 — 반쪽 요약이 저장되고
      # 나중 청크의 요약은 "이미 있음"으로 건너뛰어 영영 갱신되지 않는다.
      {:ok, s1} = Meetings.create_session(ctx.meeting)
      {:ok, s2} = Meetings.create_session(ctx.meeting)

      assert Meetings.transcription_pending?(ctx.meeting.id)

      {:ok, _} = Meetings.set_session_status(s1, "completed")
      assert Meetings.transcription_pending?(ctx.meeting.id), "s2 가 아직 남았다"

      {:ok, _} = Meetings.set_session_status(s2, "completed")
      refute Meetings.transcription_pending?(ctx.meeting.id)
    end

    test "실패한 세션은 기다리지 않는다", ctx do
      # 실패는 끝난 상태다. 여기서 기다리면 요약이 영영 안 나온다.
      {:ok, s1} = Meetings.create_session(ctx.meeting)
      {:ok, _} = Meetings.set_session_status(s1, "failed")

      refute Meetings.transcription_pending?(ctx.meeting.id)
    end

    test "업로드를 등록하면 상태가 uploaded 로 간다", ctx do
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

    test "합계가 회의에 캐시된다", ctx do
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

    test "삭제한 세션은 합계에서 빠진다", ctx do
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

  describe "전사 검증" do
    setup ctx do
      {:ok, session} = Meetings.create_session(ctx.meeting)
      Map.put(ctx, :session, session)
    end

    test "올바른 세그먼트는 저장된다", %{session: session} do
      transcript = %{
        "segments" => [
          %{"speaker" => "speaker_1", "text" => "안녕하세요", "start_ms" => 0, "end_ms" => 1500}
        ]
      }

      assert {:ok, updated} = Meetings.update_transcript(session, %{transcript: transcript})
      assert length(updated.transcript["segments"]) == 1
    end

    test "형식이 깨진 세그먼트는 거부한다", %{session: session} do
      bad = %{"segments" => [%{"speaker" => "s1"}]}
      assert {:error, changeset} = Meetings.update_transcript(session, %{transcript: bad})
      assert errors_on(changeset).transcript
    end

    test "segments 배열이 없으면 거부한다", %{session: session} do
      assert {:error, changeset} =
               Meetings.update_transcript(session, %{transcript: %{"foo" => 1}})

      assert errors_on(changeset).transcript
    end
  end

  describe "목록과 상세의 판정이 일치한다" do
    test "Reviewer 를 넘기면 목록에서도 사라진다", %{reviewer: account} do
      other = account_fixture()
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "양도할 회의"})

      # 만든 사람은 owner 이자 Reviewer 다
      assert Enum.any?(Meetings.list_meetings(account), &(&1.id == meeting.id))

      # Reviewer 만 넘긴다. owner_id 는 그대로 남는다.
      {:ok, meeting} =
        Meetings.update_permissions(meeting, %{
          reviewer_id: other.id,
          permissions: %{"view" => %{"mode" => "assignees_only", "accountIds" => []}}
        })

      # AccessLevel 은 owner_id 를 보지 않는다. 목록도 같아야 한다 —
      # 어긋나면 "목록엔 보이는데 열면 404" 가 된다.
      assert Meetings.level(meeting, account) == :lv3
      refute Enum.any?(Meetings.list_meetings(account), &(&1.id == meeting.id))

      assert Meetings.level(meeting, other) == :lv0
      assert Enum.any?(Meetings.list_meetings(other), &(&1.id == meeting.id))
    end

    test "목록에 나온 회의는 모두 열린다", %{reviewer: account} do
      other = account_fixture()
      {:ok, _} = Friends.create_friendship(other.id, account.id)
      {:ok, mine} = Meetings.create_meeting(account, %{title: "내것"})
      {:ok, theirs} = Meetings.create_meeting(other, %{title: "친구것"})

      {:ok, _} =
        Meetings.update_permissions(theirs, %{
          permissions: %{"view" => %{"mode" => "all_friends", "accountIds" => []}}
        })

      for meeting <- Meetings.list_meetings(account) do
        refute Meetings.level(meeting, account) == :lv3,
               "목록에 나왔는데 열 수 없다: #{meeting.id}"
      end

      ids = Enum.map(Meetings.list_meetings(account), & &1.id)
      assert mine.id in ids
      assert theirs.id in ids
    end
  end
end
