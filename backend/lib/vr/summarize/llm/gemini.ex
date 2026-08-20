defmodule VR.Summarize.LLM.Gemini do
  @moduledoc """
  Google Gemini 어댑터. **기본 제공자** ([04-pipeline.md](../../../../docs/04-pipeline.md)).

  `generateContent` + `responseSchema` 로 구조화 출력을 강제한다.

  ## 스키마를 손봐서 넘긴다

  Gemini 는 JSON Schema 를 그대로 받지 않는다. `additionalProperties` 를
  모르고, 속성 순서를 `propertyOrdering` 으로 따로 받는다.
  """

  alias VR.Summarize.LLM.HTTP

  @default_base "https://generativelanguage.googleapis.com/v1beta"

  def complete(provider, system, user, schema, _opts) do
    url =
      "#{base_url(provider)}/models/#{provider.model}:generateContent?key=#{provider.resolved_api_key}"

    payload = %{
      "systemInstruction" => %{"parts" => [%{"text" => system}]},
      "contents" => [%{"role" => "user", "parts" => [%{"text" => user}]}],
      "generationConfig" => %{
        "temperature" => temperature(provider),
        "maxOutputTokens" => provider.max_output_tokens,
        "responseMimeType" => "application/json",
        "responseSchema" => to_gemini_schema(schema)
      }
    }

    with {:ok, body} <- HTTP.post_json(url, [{"content-type", "application/json"}], payload),
         {:ok, text} <- extract_text(body) do
      {:ok,
       %{
         body: text,
         model: provider.model,
         provider: "gemini",
         usage: usage(body)
       }}
    end
  end

  # ── 내부 ─────────────────────────────────────────────────

  defp base_url(provider) do
    case provider.base_url do
      nil -> @default_base
      "" -> @default_base
      url -> String.trim_trailing(url, "/")
    end
  end

  defp temperature(provider) do
    provider.temperature |> Decimal.to_float()
  rescue
    _ -> 0.2
  end

  defp extract_text(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    text =
      parts
      |> Enum.map(&(&1["text"] || ""))
      |> Enum.join("")
      |> String.trim()

    if text == "", do: {:error, :empty_response}, else: {:ok, text}
  end

  # 안전 필터에 걸리면 candidates 가 비거나 finishReason 만 온다
  defp extract_text(%{"candidates" => [%{"finishReason" => reason} | _]}) do
    {:error, {:blocked, reason}}
  end

  defp extract_text(%{"promptFeedback" => %{"blockReason" => reason}}) do
    {:error, {:blocked, reason}}
  end

  defp extract_text(_), do: {:error, :empty_response}

  defp usage(%{"usageMetadata" => meta}) do
    %{
      input_tokens: meta["promptTokenCount"] || 0,
      output_tokens: meta["candidatesTokenCount"] || 0
    }
  end

  defp usage(_), do: %{input_tokens: 0, output_tokens: 0}

  @doc false
  # Gemini 는 additionalProperties 를 모르고, 순서를 propertyOrdering 으로 받는다
  def to_gemini_schema(%{"type" => "object", "properties" => properties} = schema) do
    converted = Map.new(properties, fn {key, value} -> {key, to_gemini_schema(value)} end)

    %{"type" => "object", "properties" => converted}
    |> put_if("required", schema["required"])
    |> put_if("propertyOrdering", schema["required"] || Map.keys(properties))
  end

  def to_gemini_schema(%{"type" => "array", "items" => items}) do
    %{"type" => "array", "items" => to_gemini_schema(items)}
  end

  def to_gemini_schema(%{"type" => type}), do: %{"type" => type}
  def to_gemini_schema(other), do: other

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
