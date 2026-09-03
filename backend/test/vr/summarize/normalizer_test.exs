defmodule VR.Summarize.NormalizerTest do
  use ExUnit.Case, async: true

  alias VR.Meetings.RecordingSession
  alias VR.Summarize.Normalizer

  defp sessions do
    [
      %RecordingSession{
        id: "mrss_a",
        session_index: 1,
        speaker_map: %{"speaker_1" => %{"name" => "Jane Doe"}},
        transcript: %{
          "segments" => [
            %{"speaker" => "speaker_1", "text" => "Let's ship by April 30th.", "start_ms" => 12_340},
            %{"speaker" => "speaker_2", "text" => "Sounds good.", "start_ms" => 20_000}
          ]
        }
      }
    ]
  end

  defp index, do: Normalizer.build_index(sessions())

  describe "source verification" do
    test "attaches start_ms when the actual utterance is found" do
      source = %{
        "session_id" => "mrss_a",
        "speaker" => "Jane Doe",
        "time_label" => "00:00:12",
        "quote" => "Let's ship by April 30th."
      }

      assert %{"start_ms" => 12_000, "speaker" => "Jane Doe"} =
               Normalizer.verify_source(source, index())
    end

    test "corrects a model-polished quote back to the actual utterance" do
      source = %{
        "session_id" => "mrss_a",
        "speaker" => "Jane Doe",
        "time_label" => "00:00:12",
        "quote" => "ship by end of April"
      }

      assert %{"quote" => "Let's ship by April 30th."} = Normalizer.verify_source(source, index())
    end

    test "drops a timestamp that does not exist" do
      source = %{
        "session_id" => "mrss_a",
        "speaker" => "Jane Doe",
        "time_label" => "00:05:00",
        "quote" => "made-up words"
      }

      assert Normalizer.verify_source(source, index()) == nil
    end

    test "drops an id from another session" do
      source = %{
        "session_id" => "mrss_missing",
        "speaker" => "Jane Doe",
        "time_label" => "00:00:12",
        "quote" => "Let's ship by April 30th."
      }

      assert Normalizer.verify_source(source, index()) == nil
    end

    test "does not crash when source is missing entirely" do
      assert Normalizer.verify_source(nil, index()) == nil
      assert Normalizer.verify_source(%{}, index()) == nil
    end
  end

  describe "normalize/2" do
    test "keeps the item even when no evidence is found" do
      # Better to lose the jump link than to silently lose a decision
      raw = %{
        "one_liner" => "Set the release date.",
        "decisions" => [
          %{"text" => "Ship on April 30", "source" => %{"session_id" => "missing"}}
        ]
      }

      result = Normalizer.normalize(raw, sessions())

      assert [%{"text" => "Ship on April 30", "source" => nil}] = result["decisions"]
    end

    test "drops empty items" do
      raw = %{
        "decisions" => [%{"text" => "  "}, %{"text" => "a real decision"}],
        "action_items" => [%{"what" => ""}, %{"what" => "a task", "who" => "Jane Doe"}],
        "facts" => ["", "a fact"]
      }

      result = Normalizer.normalize(raw, sessions())

      assert length(result["decisions"]) == 1
      assert length(result["action_items"]) == 1
      assert result["facts"] == ["a fact"]
    end

    test "type mismatches degrade to empty values" do
      result = Normalizer.normalize(%{"decisions" => "text", "facts" => 42}, sessions())

      assert result["decisions"] == []
      assert result["facts"] == []
      assert result["one_liner"] == ""
    end

    test "key_topics caps at 5" do
      raw = %{"key_topics" => ~w(one two three four five six seven)}
      assert length(Normalizer.normalize(raw, sessions())["key_topics"]) == 5
    end

    test "action_items survive without an assignee or due date" do
      raw = %{"action_items" => [%{"what" => "verify this"}]}

      assert [%{"who" => "", "what" => "verify this", "due" => ""}] =
               Normalizer.normalize(raw, sessions())["action_items"]
    end
  end

  describe "decode/1" do
    test "plain JSON" do
      assert {:ok, %{"a" => 1}} = Normalizer.decode(~s({"a":1}))
    end

    test "recovers JSON wrapped in code fences" do
      assert {:ok, %{"a" => 1}} = Normalizer.decode("```json\n{\"a\":1}\n```")
      assert {:ok, %{"a" => 1}} = Normalizer.decode("```\n{\"a\":1}\n```")
    end

    test "recovers JSON with prose around it" do
      assert {:ok, %{"a" => 1}} = Normalizer.decode("Here is the summary:\n{\"a\":1}\nThank you")
    end

    test "fails when it is not JSON" do
      assert {:error, :invalid_json} = Normalizer.decode("Sorry, I cannot summarize this")
      assert {:error, :invalid_json} = Normalizer.decode(nil)
    end

    test "a bare array counts as failure" do
      # summary_data must be an object
      assert {:error, :invalid_json} = Normalizer.decode("[1,2,3]")
    end
  end
end
