defmodule VR.Summarize.LLM.OpenAI do
  @moduledoc """
  OpenAI adapter. OpenAI-compatible endpoints (via `base_url`) go through here too.

  Structured output is requested with `response_format: json_schema`.
  Compatible servers may not understand it, so `Normalizer.decode/1` backs
  this up by salvaging JSON from the body even when that fails.
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

  # ── Internal ─────────────────────────────────────────────

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
