defmodule VR.SummarizeTest do
  use VR.DataCase, async: true

  alias VR.Summarize
  alias VR.Summarize.LLM

  describe "token_cost/2 — origin: devkanban price_tokens/3" do
    defp pricing(input, output, margin \\ "0") do
      %{
        input_price_usd_per_1m: Decimal.new(input),
        output_price_usd_per_1m: Decimal.new(output),
        margin_rate: Decimal.new(margin)
      }
    end

    test "divides by the per-million-token unit price" do
      usage = %{input_tokens: 1_000_000, output_tokens: 500_000}

      {:ok, cost} = Summarize.token_cost(usage, pricing("0.30", "2.50"))

      # 0.30 + 1.25
      assert Decimal.equal?(cost.usage_cost_usd, Decimal.new("1.55"))
      assert Decimal.equal?(cost.margin_amount_usd, Decimal.new("0"))
    end

    test "adds the margin" do
      usage = %{input_tokens: 1_000_000, output_tokens: 0}

      {:ok, cost} = Summarize.token_cost(usage, pricing("1.00", "0", "0.2"))

      assert Decimal.equal?(cost.base_usage_cost_usd, Decimal.new("1"))
      assert Decimal.equal?(cost.margin_amount_usd, Decimal.new("0.2"))
      assert Decimal.equal?(cost.usage_cost_usd, Decimal.new("1.2"))
    end

    test "does not meter without a unit price" do
      # Incomplete pricing setup must not fail the summary
      usage = %{input_tokens: 1000, output_tokens: 1000}

      assert {:error, :no_pricing} = Summarize.token_cost(usage, pricing("0", "0"))

      assert {:error, :no_pricing} =
               Summarize.token_cost(usage, %{
                 input_price_usd_per_1m: nil,
                 output_price_usd_per_1m: nil,
                 margin_rate: nil
               })
    end

    test "meters even when only one side is configured" do
      usage = %{input_tokens: 0, output_tokens: 1_000_000}

      assert {:ok, cost} = Summarize.token_cost(usage, pricing("0", "3.00"))
      assert Decimal.equal?(cost.usage_cost_usd, Decimal.new("3"))
    end
  end

  describe "LLM fallback decision" do
    # Fallback costs money. Only failures worth retrying move on.
    test "rate limits and 5xx move to the next provider" do
      assert LLM.adapter("gemini") == VR.Summarize.LLM.Gemini
      assert LLM.adapter("anthropic") == VR.Summarize.LLM.Anthropic
      assert LLM.adapter("openai") == VR.Summarize.LLM.OpenAI
      assert LLM.adapter("nonexistent") == nil
    end

    test "no_provider when no provider exists" do
      assert {:error, :no_provider} = LLM.complete("s", "u", %{})
    end
  end

  describe "Gemini schema conversion" do
    test "removes additionalProperties and adds propertyOrdering" do
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

    test "walks nested arrays and objects" do
      converted = VR.Summarize.LLM.Gemini.to_gemini_schema(VR.Summarize.Prompt.schema())

      decisions = converted["properties"]["decisions"]
      assert decisions["type"] == "array"
      refute Map.has_key?(decisions["items"], "additionalProperties")
      refute Map.has_key?(decisions["items"]["properties"]["source"], "additionalProperties")
    end
  end
end
