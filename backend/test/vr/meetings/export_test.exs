defmodule VR.Meetings.ExportTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Meetings
  alias VR.Meetings.Export

  setup do
    account = account_fixture()
    {:ok, meeting} = Meetings.create_meeting(account, %{title: "Quarterly Planning Meeting"})
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

  describe "transcript" do
    test "keeps session boundaries", ctx do
      sessions = [
        session(ctx.meeting, 1, [seg("speaker_1", "Let's begin", 0)]),
        session(ctx.meeting, 2, [seg("speaker_1", "Continuing on", 0)]),
        session(ctx.meeting, 3, [])
      ]

      md = Export.to_markdown(ctx.meeting, sessions)

      assert md =~ "### Session 1"
      assert md =~ "### Session 2"

      # Sessions without a transcript are still listed — a document-only reader must know what is missing
      assert md =~ "no transcript"
    end

    test "emits ascending even when sessions arrive out of order", ctx do
      a = session(ctx.meeting, 1, [seg("speaker_1", "first", 0)])
      b = session(ctx.meeting, 2, [seg("speaker_1", "later", 0)])

      md = Export.to_markdown(ctx.meeting, [b, a])

      assert :binary.match(md, "first") < :binary.match(md, "later")
    end

    test "falls back to Speaker N without a speaker name", ctx do
      md = Export.to_markdown(ctx.meeting, [session(ctx.meeting, 1, [seg("speaker_3", "words", 0)])])
      assert md =~ "**Speaker 3**"
    end

    test "timestamps are session-relative HH:MM:SS", ctx do
      # The summary's source.time_label is relative too. Wall-clock times could not be cross-referenced within the document.
      md =
        Export.to_markdown(ctx.meeting, [
          session(ctx.meeting, 1, [seg("speaker_1", "words", 754_000)])
        ])

      assert md =~ "`00:12:34`"
    end

    test "escapes Markdown symbols in speaker names", ctx do
      sessions = [
        session(ctx.meeting, 1, [seg("speaker_1", "words", 0)], %{
          "speaker_1" => %{"name" => "Jo**hn`"}
        })
      ]

      md = Export.to_markdown(ctx.meeting, sessions)

      refute md =~ "**Jo**hn"
      assert md =~ "\\*"
    end

    test "escapes leading Markdown markers in utterances", ctx do
      md =
        Export.to_markdown(ctx.meeting, [
          session(ctx.meeting, 1, [seg("speaker_1", "# an utterance that looks like a heading", 0)])
        ])

      assert md =~ "\\#"
    end
  end

  describe "summary" do
    test "no section at all without a summary", ctx do
      md = Export.to_markdown(ctx.meeting, [session(ctx.meeting, 1, [seg("speaker_1", "words", 0)])])
      refute md =~ "## Summary"
    end

    test "items without evidence still appear", ctx do
      {:ok, meeting} =
        Meetings.update_summary(ctx.meeting, %{
          summary_data: %{
            "one_liner" => "Set the release date.",
            "decisions" => [%{"text" => "Ship on April 30", "source" => nil}],
            "action_items" => [],
            "facts" => [],
            "open_questions" => [],
            "next_steps" => [],
            "key_topics" => ["release"]
          }
        })

      md = Export.to_markdown(meeting, [])

      assert md =~ "## Summary"
      assert md =~ "Ship on April 30"
      assert md =~ "**Key Topics**: release"
    end

    test "evidence timestamps use the same clock as transcript lines", ctx do
      {:ok, meeting} =
        Meetings.update_summary(ctx.meeting, %{
          summary_data: %{
            "one_liner" => "Summary",
            "decisions" => [
              %{
                "text" => "A decision",
                "source" => %{
                  "session_id" => "x",
                  "speaker" => "John Doe",
                  "time_label" => "00:12:34",
                  "quote" => "Let's do that"
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
          session(ctx.meeting, 1, [seg("speaker_1", "Let's do that", 754_000)])
        ])

      assert md =~ "`00:12:34`"
      assert md |> String.split("`00:12:34`") |> length() >= 3
    end
  end

  describe "no audio addresses in the output" do
    test "no storage address anywhere in the output", ctx do
      {:ok, session} = Meetings.create_session(ctx.meeting)
      key = VR.Storage.recording_key(ctx.meeting.id, session.id, session.started_at_unix, "webm")
      {:ok, session} = Meetings.set_storage_key(session, key)

      {:ok, session} =
        session
        |> Ecto.Changeset.change(%{
          audio_url: "https://files.example.com/#{key}",
          transcript: %{"segments" => [seg("speaker_1", "words", 0)]}
        })
        |> Repo.update()

      md = Export.to_markdown(ctx.meeting, [session])

      refute md =~ "files.example.com"
      refute md =~ key
      refute md =~ "data/meetings"
    end
  end

  describe "filenames" do
    test "removes path characters", ctx do
      {:ok, meeting} = Meetings.update_meeting(ctx.meeting, %{title: "a/b:c*d?e"})
      name = Export.filename(meeting)

      refute name =~ "/"
      refute name =~ ":"
      assert name =~ ".md"
    end

    test "default name without a title", ctx do
      {:ok, meeting} = Meetings.update_meeting(ctx.meeting, %{title: nil})
      assert Export.filename(meeting) =~ ~r/^Meeting_\d{8}\.md$/
    end

    test "non-ASCII titles are sent via filename*", ctx do
      {:ok, meeting} = Meetings.update_meeting(ctx.meeting, %{title: "Réunion générale"})
      header = Export.content_disposition(meeting)

      assert header =~ "attachment;"
      assert header =~ "filename*=UTF-8''"
      assert header =~ ~r/filename="[^"]*"/
      refute header =~ "\n"
    end

    test "very long titles are truncated", ctx do
      {:ok, meeting} = Meetings.update_meeting(ctx.meeting, %{title: String.duplicate("é", 200)})
      name = Export.filename(meeting)

      assert String.valid?(name)
      assert String.length(name) < 90
    end
  end

  describe "exportable?/2" do
    test "false with neither transcript nor summary", ctx do
      refute Export.exportable?(ctx.meeting, [])
      refute Export.exportable?(ctx.meeting, [session(ctx.meeting, 1, [])])
    end

    test "true with just a transcript", ctx do
      assert Export.exportable?(ctx.meeting, [session(ctx.meeting, 1, [seg("speaker_1", "words", 0)])])
    end
  end
end
