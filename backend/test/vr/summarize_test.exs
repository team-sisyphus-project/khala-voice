defmodule VR.SummarizeTest do
  use VR.DataCase, async: true

  alias VR.Summarize
  alias VR.Summarize.LLM

  describe "token_cost/2 — 출처: devkanban price_tokens/3" do
    defp pricing(input, output, margin \\ "0") do
      %{
        input_price_usd_per_1m: Decimal.new(input),
        output_price_usd_per_1m: Decimal.new(output),
        margin_rate: Decimal.new(margin)
      }
    end

    test "백만 토큰당 단가로 나눈다" do
      usage = %{input_tokens: 1_000_000, output_tokens: 500_000}

      {:ok, cost} = Summarize.token_cost(usage, pricing("0.30", "2.50"))

      # 0.30 + 1.25
      assert Decimal.equal?(cost.usage_cost_usd, Decimal.new("1.55"))
      assert Decimal.equal?(cost.margin_amount_usd, Decimal.new("0"))
    end

    test "마진을 가산한다" do
      usage = %{input_tokens: 1_000_000, output_tokens: 0}

      {:ok, cost} = Summarize.token_cost(usage, pricing("1.00", "0", "0.2"))

      assert Decimal.equal?(cost.base_usage_cost_usd, Decimal.new("1"))
      assert Decimal.equal?(cost.margin_amount_usd, Decimal.new("0.2"))
      assert Decimal.equal?(cost.usage_cost_usd, Decimal.new("1.2"))
    end

    test "단가가 없으면 계량하지 않는다" do
      # 요금 설정이 덜 됐다고 요약을 실패시키지 않는다
      usage = %{input_tokens: 1000, output_tokens: 1000}

      assert {:error, :no_pricing} = Summarize.token_cost(usage, pricing("0", "0"))

      assert {:error, :no_pricing} =
               Summarize.token_cost(usage, %{
                 input_price_usd_per_1m: nil,
                 output_price_usd_per_1m: nil,
                 margin_rate: nil
               })
    end

    test "한쪽만 설정돼 있어도 계량한다" do
      usage = %{input_tokens: 0, output_tokens: 1_000_000}

      assert {:ok, cost} = Summarize.token_cost(usage, pricing("0", "3.00"))
      assert Decimal.equal?(cost.usage_cost_usd, Decimal.new("3"))
    end
  end

  describe "LLM 폴백 판단" do
    # 폴백은 돈이 드는 판단이다. 재시도할 값어치가 있는 실패만 넘어간다.
    test "레이트리밋과 5xx 는 다음 제공자로 넘어간다" do
      assert LLM.adapter("gemini") == VR.Summarize.LLM.Gemini
      assert LLM.adapter("anthropic") == VR.Summarize.LLM.Anthropic
      assert LLM.adapter("openai") == VR.Summarize.LLM.OpenAI
      assert LLM.adapter("없는것") == nil
    end

    test "제공자가 하나도 없으면 no_provider" do
      assert {:error, :no_provider} = LLM.complete("s", "u", %{})
    end
  end

  describe "Gemini 스키마 변환" do
    test "additionalProperties 를 빼고 propertyOrdering 을 넣는다" do
      schema = %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["a"],
        "properties" => %{"a" => %{"type" => "string"}}
      }

      converted = VR.Summarize.LLM.Gemini.to_gemini_schema(schema)

      refute Map.has_key?(converted, "additionalProperties")
      assert converted["propertyOrdering"] == ["a"]
      assert converted["required"] == ["a"]
    end

    test "중첩 배열·객체까지 훑는다" do
      converted = VR.Summarize.LLM.Gemini.to_gemini_schema(VR.Summarize.Prompt.schema())

      decisions = converted["properties"]["decisions"]
      assert decisions["type"] == "array"
      refute Map.has_key?(decisions["items"], "additionalProperties")
      refute Map.has_key?(decisions["items"]["properties"]["source"], "additionalProperties")
    end
  end
end
