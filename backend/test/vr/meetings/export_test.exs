defmodule VR.Meetings.ExportTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Meetings
  alias VR.Meetings.Export

  setup do
    account = account_fixture()
    {:ok, meeting} = Meetings.create_meeting(account, %{title: "분기 계획 회의"})
    %{account: account, meeting: meeting}
  end

  defp session(meeting, index, segments, speaker_map \\ %{}) do
    {:ok, session} = Meetings.create_session(meeting)

    {:ok, session} =
      session
      |> Ecto.Changeset.change(%{
        session_index: index,
        duration_seconds: 600,
        transcript: if(segments == [], do: nil, else: %{"segments" => segments}),
        speaker_map: speaker_map
      })
      |> Repo.update()

    session
  end

  defp seg(speaker, text, start_ms),
    do: %{
      "speaker" => speaker,
      "text" => text,
      "start_ms" => start_ms,
      "end_ms" => start_ms + 3000
    }

  describe "전사" do
    test "세션 경계를 남긴다", ctx do
      sessions = [
        session(ctx.meeting, 1, [seg("speaker_1", "시작합니다", 0)]),
        session(ctx.meeting, 2, [seg("speaker_1", "이어서", 0)]),
        session(ctx.meeting, 3, [])
      ]

      md = Export.to_markdown(ctx.meeting, sessions)

      assert md =~ "### 세션 1"
      assert md =~ "### 세션 2"

      # 전사 없는 세션도 남긴다 — 문서만 받은 사람이 빠진 구간을 알아야 한다
      assert md =~ "전사 없음"
    end

    test "세션 순서가 뒤바뀌어 들어와도 오름차순으로 낸다", ctx do
      a = session(ctx.meeting, 1, [seg("speaker_1", "먼저", 0)])
      b = session(ctx.meeting, 2, [seg("speaker_1", "나중", 0)])

      md = Export.to_markdown(ctx.meeting, [b, a])

      assert :binary.match(md, "먼저") < :binary.match(md, "나중")
    end

    test "화자 이름이 없으면 화자 N", ctx do
      md = Export.to_markdown(ctx.meeting, [session(ctx.meeting, 1, [seg("speaker_3", "말", 0)])])
      assert md =~ "**화자 3**"
    end

    test "시각은 세션 내 상대 HH:MM:SS", ctx do
      # 요약의 source.time_label 도 상대 시각이다. 벽시계로 쓰면 문서 안에서 대조가 안 된다.
      md =
        Export.to_markdown(ctx.meeting, [
          session(ctx.meeting, 1, [seg("speaker_1", "말", 754_000)])
        ])

      assert md =~ "`00:12:34`"
    end

    test "화자 이름의 마크다운 기호를 이스케이프한다", ctx do
      sessions = [
        session(ctx.meeting, 1, [seg("speaker_1", "말", 0)], %{
          "speaker_1" => %{"name" => "김**철수`"}
        })
      ]

      md = Export.to_markdown(ctx.meeting, sessions)

      refute md =~ "**김**철수"
      assert md =~ "\\*"
    end

    test "발화 줄머리 기호를 이스케이프한다", ctx do
      md =
        Export.to_markdown(ctx.meeting, [
          session(ctx.meeting, 1, [seg("speaker_1", "# 제목처럼 보이는 발화", 0)])
        ])

      assert md =~ "\\#"
    end
  end

  describe "요약" do
    test "요약이 없으면 섹션 자체가 없다", ctx do
      md = Export.to_markdown(ctx.meeting, [session(ctx.meeting, 1, [seg("speaker_1", "말", 0)])])
      refute md =~ "## 요약"
    end

    test "근거가 없는 항목도 남는다", ctx do
      {:ok, meeting} =
        Meetings.update_summary(ctx.meeting, %{
          summary_data: %{
            "one_liner" => "배포 일정을 정했다.",
            "decisions" => [%{"text" => "4월 30일 배포", "source" => nil}],
            "action_items" => [],
            "facts" => [],
            "open_questions" => [],
            "next_steps" => [],
            "key_topics" => ["배포"]
          }
        })

      md = Export.to_markdown(meeting, [])

      assert md =~ "## 요약"
      assert md =~ "4월 30일 배포"
      assert md =~ "**핵심 주제**: 배포"
    end

    test "근거의 시각이 전사 줄과 같은 시계를 쓴다", ctx do
      {:ok, meeting} =
        Meetings.update_summary(ctx.meeting, %{
          summary_data: %{
            "one_liner" => "요약",
            "decisions" => [
              %{
                "text" => "결정",
                "source" => %{
                  "session_id" => "x",
                  "speaker" => "김철수",
                  "time_label" => "00:12:34",
                  "quote" => "그렇게 합시다"
                }
              }
            ],
            "action_items" => [],
            "facts" => [],
            "open_questions" => [],
            "next_steps" => [],
            "key_topics" => []
          }
        })

      md =
        Export.to_markdown(meeting, [
          session(ctx.meeting, 1, [seg("speaker_1", "그렇게 합시다", 754_000)])
        ])

      assert md =~ "`00:12:34`"
      assert md |> String.split("`00:12:34`") |> length() >= 3
    end
  end

  describe "오디오 주소를 넣지 않는다" do
    test "출력 어디에도 저장 주소가 없다", ctx do
      {:ok, session} = Meetings.create_session(ctx.meeting)
      key = VR.Storage.recording_key(ctx.meeting.id, session.id, session.started_at_unix, "webm")
      {:ok, session} = Meetings.set_storage_key(session, key)

      {:ok, session} =
        session
        |> Ecto.Changeset.change(%{
          audio_url: "https://files.example.com/#{key}",
          transcript: %{"segments" => [seg("speaker_1", "말", 0)]}
        })
        |> Repo.update()

      md = Export.to_markdown(ctx.meeting, [session])

      refute md =~ "files.example.com"
      refute md =~ key
      refute md =~ "data/meetings"
    end
  end

  describe "파일명" do
    test "경로 문자를 지운다", ctx do
      {:ok, meeting} = Meetings.update_meeting(ctx.meeting, %{title: "a/b:c*d?e"})
      name = Export.filename(meeting)

      refute name =~ "/"
      refute name =~ ":"
      assert name =~ ".md"
    end

    test "제목이 없으면 기본 이름", ctx do
      {:ok, meeting} = Meetings.update_meeting(ctx.meeting, %{title: nil})
      assert Export.filename(meeting) =~ ~r/^회의_\d{8}\.md$/
    end

    test "한글 제목은 filename* 로 보낸다", ctx do
      header = Export.content_disposition(ctx.meeting)

      assert header =~ "attachment;"
      assert header =~ "filename*=UTF-8''"
      assert header =~ ~r/filename="[^"]*"/
      refute header =~ "\n"
    end

    test "제목이 아주 길어도 자른다", ctx do
      {:ok, meeting} = Meetings.update_meeting(ctx.meeting, %{title: String.duplicate("가", 200)})
      name = Export.filename(meeting)

      assert String.valid?(name)
      assert String.length(name) < 90
    end
  end

  describe "exportable?/2" do
    test "전사도 요약도 없으면 false", ctx do
      refute Export.exportable?(ctx.meeting, [])
      refute Export.exportable?(ctx.meeting, [session(ctx.meeting, 1, [])])
    end

    test "전사만 있어도 true", ctx do
      assert Export.exportable?(ctx.meeting, [session(ctx.meeting, 1, [seg("speaker_1", "말", 0)])])
    end
  end
end
