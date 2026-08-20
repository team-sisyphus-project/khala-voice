defmodule VR.Summarize.Prompt do
  @moduledoc """
  요약 프롬프트.

  **출처: sisyphus** n8n `autosquad-meeting-summary.json` 의 시스템 프롬프트를
  그대로 옮겼다. n8n 을 걷어내면서 프롬프트만 코드로 내려왔다.

  ## 왜 이렇게 빡빡한가

  이 제품의 핵심은 **요약 항목을 누르면 그 말이 나온 지점으로 점프**하는 것이다.
  그러려면 LLM 이 `source` 를 **날조하지 않고** 라벨에서 그대로 읽어야 한다.
  "축약 금지 · 번역 금지 · 못 읽으면 빈 문자열" 규칙을 느슨하게 만들면
  인용이 원문과 어긋나 점프가 엉뚱한 곳으로 간다.
  """

  @system """
  당신은 회의 전사를 구조화된 요약으로 바꾸는 도구다. 창작하지 않는다.

  ## 입력 형식

  각 줄은 다음과 같다.

      [<session_id>|<speaker>|<HH:MM:SS>] 발화 내용

  ## source 추출 규칙 (반드시 지킬 것)

  - `session_id` = `[` 와 첫 번째 `|` 사이의 토큰
  - `speaker` = 두 번째 토큰
  - `time_label` = 세 번째 토큰. `HH:MM:SS` 형식 그대로 옮긴다
  - `quote` = `]` 뒤의 발화 **전문**. 라벨은 포함하지 않는다

  `quote` 는 전사에 있는 문자열을 **그대로** 복사한다.
  축약하지 않는다. 번역하지 않는다. 의역하지 않는다. 다듬지 않는다.
  라벨에서 읽어낼 수 없으면 해당 필드를 빈 문자열로 둔다.
  **없는 내용을 지어내지 않는다.**

  ## 각 항목의 기준

  - `one_liner`: 결론 중심 1~2문장. 안건 나열이 아니라 **무엇이 정해졌는지**
  - `decisions`: 확정된 결정만. 논의 중이면 `open_questions` 로
  - `action_items`: 실행 동사가 있는 작업. 담당자·기한이 없으면 빈 문자열
  - `facts`: 전사에 명시된 객관적 사실 (수치·날짜·이름·지표)
  - `open_questions`: 제기됐지만 이 회의에서 결론나지 않은 것
  - `next_steps`: `action_items` 에 없는 향후 일정·마일스톤
  - `key_topics`: 1~3단어 명사구. 최대 5개

  ## 출력

  JSON 만 출력한다. 설명·머리말·코드펜스를 붙이지 않는다.
  해당 항목이 없으면 빈 배열을 쓴다. 억지로 채우지 않는다.
  전사와 같은 언어로 쓴다.
  """

  @doc "시스템 프롬프트."
  def system, do: @system

  @doc """
  사용자 프롬프트. 직렬화된 전사를 감싼다.

  회의 제목은 맥락으로만 준다 — 제목을 근거로 삼아 요약을 지어내지 않도록
  "전사에 없으면 쓰지 않는다"를 다시 못박는다.
  """
  def user(title, transcript_text) do
    """
    회의 제목: #{present(title) || "(없음)"}

    아래 전사를 요약하라. 제목은 맥락일 뿐이다. 전사에 없는 내용은 쓰지 않는다.

    ---
    #{transcript_text}
    ---
    """
  end

  @doc """
  출력 JSON 스키마. 제공자마다 형식이 달라 어댑터가 변환한다.

  `additionalProperties: false` 로 잠근다 — 모델이 임의 필드를 만들면
  검증에서 걸러야 하는데, 애초에 못 만들게 하는 편이 싸다.
  """
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => [
        "one_liner",
        "decisions",
        "action_items",
        "facts",
        "open_questions",
        "next_steps",
        "key_topics"
      ],
      "properties" => %{
        "one_liner" => %{"type" => "string"},
        "decisions" => %{"type" => "array", "items" => sourced_item()},
        "action_items" => %{"type" => "array", "items" => action_item()},
        "facts" => string_array(),
        "open_questions" => string_array(),
        "next_steps" => string_array(),
        "key_topics" => string_array()
      }
    }
  end

  defp sourced_item do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["text", "source"],
      "properties" => %{
        "text" => %{"type" => "string"},
        "source" => source()
      }
    }
  end

  defp action_item do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["who", "what", "due", "source"],
      "properties" => %{
        "who" => %{"type" => "string"},
        "what" => %{"type" => "string"},
        "due" => %{"type" => "string"},
        "source" => source()
      }
    }
  end

  defp source do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["session_id", "speaker", "time_label", "quote"],
      "properties" => %{
        "session_id" => %{"type" => "string"},
        "speaker" => %{"type" => "string"},
        "time_label" => %{"type" => "string"},
        "quote" => %{"type" => "string"}
      }
    }
  end

  defp string_array, do: %{"type" => "array", "items" => %{"type" => "string"}}

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
