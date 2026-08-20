defmodule VR.Summarize.LLM.Anthropic do
  @moduledoc """
  Anthropic Claude 어댑터.

  ## 도구로 구조를 강제한다

  Messages API 에는 `response_format` 이 없다. 대신 **스키마를 도구로 주고
  그 도구를 쓰라고 강제**하면(`tool_choice`) 인자가 곧 구조화 출력이 된다.
  모델이 산문을 섞을 여지가 없어진다.
  """

  alias VR.Summarize.LLM.HTTP

  @default_base "https://api.anthropic.com/v1"
  @version "2023-06-01"
  @tool_name "emit_summary"

  def complete(provider, system, user, schema, _opts) do
    payload = %{
      "model" => provider.model,
      "max_tokens" => provider.max_output_tokens,
      "temperature" => temperature(provider),
      "system" => system,
      "messages" => [%{"role" => "user", "content" => user}],
      "tools" => [
        %{
          "name" => @tool_name,
          "description" => "회의 요약을 구조화해 제출한다",
          "input_schema" => schema
        }
      ],
      "tool_choice" => %{"type" => "tool", "name" => @tool_name}
    }

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", provider.resolved_api_key},
      {"anthropic-version", @version}
    ]

    with {:ok, body} <- HTTP.post_json("#{base_url(provider)}/messages", headers, payload),
         {:ok, text} <- extract_text(body) do
      {:ok, %{body: text, model: provider.model, provider: "anthropic", usage: usage(body)}}
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

  defp extract_text(%{"content" => blocks}) when is_list(blocks) do
    tool_input =
      Enum.find_value(blocks, fn
        %{"type" => "tool_use", "input" => input} when is_map(input) -> input
        _ -> nil
      end)

    cond do
      tool_input ->
        {:ok, Jason.encode!(tool_input)}

      # 도구를 강제했는데도 산문만 왔다면 본문에서 JSON 을 건져 본다
      text = joined_text(blocks) ->
        {:ok, text}

      true ->
        {:error, :empty_response}
    end
  end

  defp extract_text(_), do: {:error, :empty_response}

  defp joined_text(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(&(&1["text"] || ""))
    |> Enum.join("")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp usage(%{"usage" => usage}) do
    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0
    }
  end

  defp usage(_), do: %{input_tokens: 0, output_tokens: 0}
end
