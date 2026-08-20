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

  describe "직렬화 규약" do
    test "[session_id|speaker|HH:MM:SS] 형식으로 만든다" do
      s =
        session("mrss_a", [seg("speaker_1", "안녕하세요", 0)], %{
          "speaker_1" => %{"name" => "홍길동"}
        })

      assert Serializer.session_lines(s) == ["[mrss_a|홍길동|00:00:00] 안녕하세요"]
    end

    test "시각은 항상 시간 자리까지 쓴다" do
      # 프롬프트가 토막을 세 개로 기대한다. mm:ss 로 줄이면 파싱이 어긋난다.
      assert Serializer.time_label(0) == "00:00:00"
      assert Serializer.time_label(65_000) == "00:01:05"
      assert Serializer.time_label(3_725_000) == "01:02:05"
    end

    test "맵에 없는 화자는 화자 N 으로 부른다" do
      s = session("mrss_a", [seg("speaker_2", "네", 1000)])
      assert Serializer.session_lines(s) == ["[mrss_a|화자 2|00:00:01] 네"]
    end

    test "화자 이름의 구분자를 지운다" do
      # `|` 가 이름에 남으면 프롬프트가 라벨을 잘못 자른다
      s =
        session("mrss_a", [seg("speaker_1", "네", 0)], %{
          "speaker_1" => %{"name" => "김|철][수"}
        })

      assert Serializer.session_lines(s) == ["[mrss_a|김 철  수|00:00:00] 네"]
    end

    test "이름이 구분자뿐이면 화자 N 으로 되돌린다" do
      s = session("mrss_a", [seg("speaker_1", "네", 0)], %{"speaker_1" => %{"name" => "||"}})
      assert Serializer.session_lines(s) == ["[mrss_a|화자 1|00:00:00] 네"]
    end

    test "빈 발화는 버린다" do
      s = session("mrss_a", [seg("speaker_1", "  ", 0), seg("speaker_1", "네", 1000)])
      assert length(Serializer.session_lines(s)) == 1
    end
  end

  describe "serialize/1" do
    test "세션 순서대로 잇는다" do
      a = session("mrss_a", [seg("speaker_1", "먼저", 0)], %{}, 1)
      b = session("mrss_b", [seg("speaker_1", "나중", 0)], %{}, 2)

      %{text: text} = Serializer.serialize([b, a])

      assert text == "[mrss_a|화자 1|00:00:00] 먼저\n[mrss_b|화자 1|00:00:00] 나중"
    end

    test "전사 없는 세션은 제외 목록에 남긴다" do
      a = session("mrss_a", [seg("speaker_1", "있음", 0)])
      b = %RecordingSession{id: "mrss_b", session_index: 2, transcript: nil, speaker_map: %{}}

      result = Serializer.serialize([a, b])

      assert result.included_session_ids == ["mrss_a"]
      assert result.skipped_session_ids == ["mrss_b"]
    end

    test "전부 비면 빈 문자열" do
      assert %{text: ""} = Serializer.serialize([])
    end

    test "짧으면 덩어리가 하나다" do
      s = session("mrss_a", [seg("speaker_1", "짧다", 0)])
      assert %{chunks: [_one]} = Serializer.serialize([s])
    end

    test "상한을 넘으면 **자르지 않고** 나눈다" do
      # 자르면 뒷부분이 요약에서 조용히 사라진다. 회의록에서 이건 최악이다 —
      # 요약은 멀쩡해 보이는데 마지막 30분의 결정사항이 통째로 없다.
      # (sisyphus 는 여기서 60,000자에 잘랐다: `meetings.ex:710`)
      long = String.duplicate("가", 300)
      segments = for i <- 0..600, do: seg("speaker_1", long, i * 1000)
      s = session("mrss_a", segments)

      assert %{text: text, chunks: chunks} = Serializer.serialize([s])
      assert length(chunks) > 1, "상한을 넘었으면 나뉘어야 한다"

      # **아무것도 잃지 않는다** — 덩어리를 도로 이으면 원본과 같다
      assert Enum.join(chunks, "\n") == text

      # 덩어리마다 상한 안에 든다
      for c <- chunks, do: assert(String.length(c) <= Serializer.chunk_chars())

      # 줄 한가운데를 자르면 라벨이 깨진 발화가 남아 출처가 틀린 요약이 나온다
      for c <- chunks, line <- String.split(c, "\n") do
        assert String.starts_with?(line, "[mrss_a|")
      end
    end

    test "혼자서 상한을 넘는 발화는 그 줄만 담는다" do
      # 자르는 것보다 모델이 알아서 줄이게 두는 편이 낫다
      huge = String.duplicate("나", Serializer.chunk_chars() + 100)
      s = session("mrss_a", [seg("speaker_1", "짧다", 0), seg("speaker_1", huge, 1000)])

      assert %{chunks: chunks} = Serializer.serialize([s])
      assert length(chunks) == 2
      assert Enum.any?(chunks, &(String.length(&1) > Serializer.chunk_chars()))
    end
  end

  describe "parse_time_label/1" do
    test "왕복한다" do
      for ms <- [0, 1000, 65_000, 3_725_000] do
        assert Serializer.parse_time_label(Serializer.time_label(ms)) == ms
      end
    end

    test "mm:ss 도 받는다" do
      assert Serializer.parse_time_label("01:05") == 65_000
    end

    test "이상한 값은 nil" do
      assert Serializer.parse_time_label("어제") == nil
      assert Serializer.parse_time_label(nil) == nil
      assert Serializer.parse_time_label("1:2:3:4") == nil
    end
  end
end
