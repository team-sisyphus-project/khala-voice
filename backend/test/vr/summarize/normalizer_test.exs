defmodule VR.Summarize.NormalizerTest do
  use ExUnit.Case, async: true

  alias VR.Meetings.RecordingSession
  alias VR.Summarize.Normalizer

  defp sessions do
    [
      %RecordingSession{
        id: "mrss_a",
        session_index: 1,
        speaker_map: %{"speaker_1" => %{"name" => "홍길동"}},
        transcript: %{
          "segments" => [
            %{"speaker" => "speaker_1", "text" => "4월 30일까지 배포합시다.", "start_ms" => 12_340},
            %{"speaker" => "speaker_2", "text" => "네 좋습니다.", "start_ms" => 20_000}
          ]
        }
      }
    ]
  end

  defp index, do: Normalizer.build_index(sessions())

  describe "source 검증" do
    test "실제 발화를 찾으면 start_ms 를 붙여 준다" do
      source = %{
        "session_id" => "mrss_a",
        "speaker" => "홍길동",
        "time_label" => "00:00:12",
        "quote" => "4월 30일까지 배포합시다."
      }

      assert %{"start_ms" => 12_000, "speaker" => "홍길동"} =
               Normalizer.verify_source(source, index())
    end

    test "모델이 인용을 다듬어 왔으면 실제 발화로 교정한다" do
      source = %{
        "session_id" => "mrss_a",
        "speaker" => "홍길동",
        "time_label" => "00:00:12",
        "quote" => "4월 말까지 배포"
      }

      assert %{"quote" => "4월 30일까지 배포합시다."} = Normalizer.verify_source(source, index())
    end

    test "없는 시각이면 버린다" do
      source = %{
        "session_id" => "mrss_a",
        "speaker" => "홍길동",
        "time_label" => "00:05:00",
        "quote" => "지어낸 말"
      }

      assert Normalizer.verify_source(source, index()) == nil
    end

    test "다른 세션의 id 면 버린다" do
      source = %{
        "session_id" => "mrss_없음",
        "speaker" => "홍길동",
        "time_label" => "00:00:12",
        "quote" => "4월 30일까지 배포합시다."
      }

      assert Normalizer.verify_source(source, index()) == nil
    end

    test "source 가 아예 없어도 터지지 않는다" do
      assert Normalizer.verify_source(nil, index()) == nil
      assert Normalizer.verify_source(%{}, index()) == nil
    end
  end

  describe "normalize/2" do
    test "근거를 못 찾아도 항목은 남긴다" do
      # 결정사항이 조용히 사라지는 것보다 점프를 포기하는 편이 낫다
      raw = %{
        "one_liner" => "배포 일정을 정했다.",
        "decisions" => [
          %{"text" => "4월 30일 배포", "source" => %{"session_id" => "없음"}}
        ]
      }

      result = Normalizer.normalize(raw, sessions())

      assert [%{"text" => "4월 30일 배포", "source" => nil}] = result["decisions"]
    end

    test "빈 항목은 버린다" do
      raw = %{
        "decisions" => [%{"text" => "  "}, %{"text" => "진짜 결정"}],
        "action_items" => [%{"what" => ""}, %{"what" => "할 일", "who" => "홍길동"}],
        "facts" => ["", "사실"]
      }

      result = Normalizer.normalize(raw, sessions())

      assert length(result["decisions"]) == 1
      assert length(result["action_items"]) == 1
      assert result["facts"] == ["사실"]
    end

    test "타입이 어긋나도 빈 값으로 받는다" do
      result = Normalizer.normalize(%{"decisions" => "글자", "facts" => 42}, sessions())

      assert result["decisions"] == []
      assert result["facts"] == []
      assert result["one_liner"] == ""
    end

    test "key_topics 는 5개까지" do
      raw = %{"key_topics" => ~w(하나 둘 셋 넷 다섯 여섯 일곱)}
      assert length(Normalizer.normalize(raw, sessions())["key_topics"]) == 5
    end

    test "action_item 은 담당자·기한이 없어도 남는다" do
      raw = %{"action_items" => [%{"what" => "확인하기"}]}

      assert [%{"who" => "", "what" => "확인하기", "due" => ""}] =
               Normalizer.normalize(raw, sessions())["action_items"]
    end
  end

  describe "decode/1" do
    test "그냥 JSON" do
      assert {:ok, %{"a" => 1}} = Normalizer.decode(~s({"a":1}))
    end

    test "코드펜스에 감싸여 와도 건져낸다" do
      assert {:ok, %{"a" => 1}} = Normalizer.decode("```json\n{\"a\":1}\n```")
      assert {:ok, %{"a" => 1}} = Normalizer.decode("```\n{\"a\":1}\n```")
    end

    test "앞뒤에 말이 붙어 와도 건져낸다" do
      assert {:ok, %{"a" => 1}} = Normalizer.decode("요약입니다:\n{\"a\":1}\n감사합니다")
    end

    test "JSON 이 아니면 실패" do
      assert {:error, :invalid_json} = Normalizer.decode("죄송합니다, 요약할 수 없습니다")
      assert {:error, :invalid_json} = Normalizer.decode(nil)
    end

    test "배열만 오면 실패로 본다" do
      # summary_data 는 객체여야 한다
      assert {:error, :invalid_json} = Normalizer.decode("[1,2,3]")
    end
  end
end
