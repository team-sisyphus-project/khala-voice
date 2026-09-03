defmodule VR.Khala.MCPClient do
  @moduledoc """
  The client side of Khala MCP. JSON-RPC 2.0 over HTTP.

  ## Responses come in two forms

  MCP streamable HTTP answers on the same endpoint with either
  `application/json` or `text/event-stream`. The server decides which, so
  **we read both** — handling only one fails silently the day the server switches.

  ## We distinguish errors

  | Response | Meaning | What we do |
  |---|---|---|
  | 401 | Token is dead | Refresh, or if that fails, **do not retry** |
  | `result.isError` | Tool refused | Show the reason to the user |
  | Anything else | Transient | The worker retries |

  Treating a 401 as transient makes the worker retry a dead token forever.
  """

  require Logger

  @protocol "2025-06-18"

  @doc """
  Call a tool.

  We do not run `initialize` each time — these are stateless HTTP calls with no
  session continuity. Khala accepts `tools/call` directly.
  """
  def call_tool(url, access_token, name, args) do
    request(url, access_token, "tools/call", %{"name" => name, "arguments" => args})
  end

  @doc "List the available tools. Diagnostic use."
  def list_tools(url, access_token), do: request(url, access_token, "tools/list", %{})

  defp request(url, access_token, method, params) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

    headers = [
      {"authorization", "Bearer " <> access_token},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", @protocol}
    ]

    case Req.post(url, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: raw}} when status in 200..299 ->
        decode(raw)

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # For streamed responses, collect the `data:` lines and use the last JSON.
  defp decode(raw) when is_binary(raw) do
    raw
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&(&1 |> String.replace_prefix("data:", "") |> String.trim()))
    |> Enum.reduce(nil, fn line, acc ->
      case Jason.decode(line) do
        {:ok, decoded} -> decoded
        _ -> acc
      end
    end)
    |> case do
      nil -> {:error, :unparsable_response}
      decoded -> decode(decoded)
    end
  end

  defp decode(%{"error" => %{"message" => message}}), do: {:error, {:rpc, message}}

  defp decode(%{"result" => result}) when is_map(result) do
    if result["isError"] do
      {:error, {:tool_error, text_of(result)}}
    else
      {:ok, result}
    end
  end

  defp decode(_), do: {:error, :unparsable_response}

  @doc """
  Extract text from a tool response.

  MCP tools answer with `content: [%{type: "text", text: ...}]`. Khala puts
  JSON as a string inside that, so one more layer needs unwrapping.
  """
  def text_of(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  def text_of(_), do: ""

  @doc "Decode the tool response text as JSON. If it is not JSON, return it as is."
  def json_of(result) do
    text = text_of(result)

    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      _ -> text
    end
  end
end
