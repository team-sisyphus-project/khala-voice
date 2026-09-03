defmodule VR.Summarize.SerializerTest do
  use ExUnit.Case, async: true

  alias VR.Meetings.RecordingSession
  alias VR.Summarize.Serializer

  defp session(id, segments, speaker_map \\ %{}, index \\ 1) do
    %RecordingSession{
      id: id,
      session_index: index,
      transcript: %{"segments" => segments},
      speaker_map: speaker_map
    }
  end

  defp seg(speaker, text, start_ms),
    do: %{"speaker" => speaker, "text" => text, "start_ms" => start_ms}

  describe "serialization contract" do
    test "produces the [session_id|speaker|HH:MM:SS] format" do
      s =
        session("mrss_a", [seg("speaker_1", "Hello everyone", 0)], %{
          "speaker_1" => %{"name" => "Jane Doe"}
        })

      assert Serializer.session_lines(s) == ["[mrss_a|Jane Doe|00:00:00] Hello everyone"]
    end

    test "timestamps always include the hours place" do
      # The prompt expects three parts. Shortening to mm:ss breaks parsing.
      assert Serializer.time_label(0) == "00:00:00"
      assert Serializer.time_label(65_000) == "00:01:05"
      assert Serializer.time_label(3_725_000) == "01:02:05"
    end

    test "speakers missing from the map are called Speaker N" do
      s = session("mrss_a", [seg("speaker_2", "Yes", 1000)])
      assert Serializer.session_lines(s) == ["[mrss_a|Speaker 2|00:00:01] Yes"]
    end

    test "strips delimiters from speaker names" do
      # A `|` left in the name makes the prompt cut the label wrong
      s =
        session("mrss_a", [seg("speaker_1", "Yes", 0)], %{
          "speaker_1" => %{"name" => "Jo|hn][Doe"}
        })

      assert Serializer.session_lines(s) == ["[mrss_a|Jo hn  Doe|00:00:00] Yes"]
    end

    test "names made only of delimiters fall back to Speaker N" do
      s = session("mrss_a", [seg("speaker_1", "Yes", 0)], %{"speaker_1" => %{"name" => "||"}})
      assert Serializer.session_lines(s) == ["[mrss_a|Speaker 1|00:00:00] Yes"]
    end

    test "drops empty utterances" do
      s = session("mrss_a", [seg("speaker_1", "  ", 0), seg("speaker_1", "Yes", 1000)])
      assert length(Serializer.session_lines(s)) == 1
    end
  end

  describe "serialize/1" do
    test "joins in session order" do
      a = session("mrss_a", [seg("speaker_1", "first", 0)], %{}, 1)
      b = session("mrss_b", [seg("speaker_1", "later", 0)], %{}, 2)

      %{text: text} = Serializer.serialize([b, a])

      assert text == "[mrss_a|Speaker 1|00:00:00] first\n[mrss_b|Speaker 1|00:00:00] later"
    end

    test "sessions without transcripts land in the skipped list" do
      a = session("mrss_a", [seg("speaker_1", "present", 0)])
      b = %RecordingSession{id: "mrss_b", session_index: 2, transcript: nil, speaker_map: %{}}

      result = Serializer.serialize([a, b])

      assert result.included_session_ids == ["mrss_a"]
      assert result.skipped_session_ids == ["mrss_b"]
    end

    test "empty input yields an empty string" do
      assert %{text: ""} = Serializer.serialize([])
    end

    test "short input is a single chunk" do
      s = session("mrss_a", [seg("speaker_1", "short", 0)])
      assert %{chunks: [_one]} = Serializer.serialize([s])
    end

    test "over the cap it splits — it does NOT truncate" do
      # Truncating silently drops the tail from the summary. For meeting notes that is the worst case —
      # the summary looks fine while every decision from the last 30 minutes is simply gone.
      # (sisyphus truncated at 60,000 chars here: `meetings.ex:710`)
      long = String.duplicate("a", 300)
      segments = for i <- 0..600, do: seg("speaker_1", long, i * 1000)
      s = session("mrss_a", segments)

      assert %{text: text, chunks: chunks} = Serializer.serialize([s])
      assert length(chunks) > 1, "over the cap it must split"

      # **Nothing is lost** — rejoining the chunks reproduces the original
      assert Enum.join(chunks, "\n") == text

      # Each chunk fits within the cap
      for c <- chunks, do: assert(String.length(c) <= Serializer.chunk_chars())

      # Splitting mid-line leaves an utterance with a broken label, yielding wrongly-attributed summaries
      for c <- chunks, line <- String.split(c, "\n") do
        assert String.starts_with?(line, "[mrss_a|")
      end
    end

    test "an utterance exceeding the cap on its own gets its own chunk" do
      # Better to let the model condense it than to truncate
      huge = String.duplicate("b", Serializer.chunk_chars() + 100)
      s = session("mrss_a", [seg("speaker_1", "short", 0), seg("speaker_1", huge, 1000)])

      assert %{chunks: chunks} = Serializer.serialize([s])
      assert length(chunks) == 2
      assert Enum.any?(chunks, &(String.length(&1) > Serializer.chunk_chars()))
    end
  end

  describe "parse_time_label/1" do
    test "round-trips" do
      for ms <- [0, 1000, 65_000, 3_725_000] do
        assert Serializer.parse_time_label(Serializer.time_label(ms)) == ms
      end
    end

    test "accepts mm:ss too" do
      assert Serializer.parse_time_label("01:05") == 65_000
    end

    test "weird values are nil" do
      assert Serializer.parse_time_label("yesterday") == nil
      assert Serializer.parse_time_label(nil) == nil
      assert Serializer.parse_time_label("1:2:3:4") == nil
    end
  end
end
