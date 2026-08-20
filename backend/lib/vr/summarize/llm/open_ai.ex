defmodule VR.Summarize.LLM.OpenAI do
  @moduledoc """
  OpenAI 어댑터. OpenAI 호환 엔드포인트(`base_url` 지정)도 여기로 받는다.

  `response_format: json_schema` 로 구조화 출력을 건다.
  호환 서버가 이를 모를 수 있으므로, 실패해도 본문에서 JSON 을
  건져낼 수 있게 `Normalizer.decode/1` 이 뒤를 받친다.
  """

  alias VR.Summarize.LLM.HTTP

  @default_base "https://api.openai.com/v1"

  def complete(provider, system, user, schema, _opts) do
    payload = %{
      "model" => provider.model,
      "temperature" => temperature(provider),
      "max_completion_tokens" => provider.max_output_tokens,
      "messages" => [
        %{"role" => "system", "content" => system},
        %{"role" => "user", "content" => user}
      ],
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "meeting_summary",
          "strict" => true,
          "schema" => schema
        }
      }
    }

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{provider.resolved_api_key}"}
    ]

    with {:ok, body} <- HTTP.post_json("#{base_url(provider)}/chat/completions", headers, payload),
         {:ok, text} <- extract_text(body) do
      {:ok, %{body: text, model: provider.model, provider: "openai", usage: usage(body)}}
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

  defp extract_text(%{"choices" => [%{"message" => message} | _]}) do
    case String.trim(message["content"] || "") do
      "" -> {:error, :empty_response}
      text -> {:ok, text}
    end
  end

  defp extract_text(_), do: {:error, :empty_response}

  defp usage(%{"usage" => usage}) do
    %{
      input_tokens: usage["prompt_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || 0
    }
  end

  defp usage(_), do: %{input_tokens: 0, output_tokens: 0}
end
