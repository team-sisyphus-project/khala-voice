defmodule VR.Khala.MCPClient do
  @moduledoc """
  칼라 MCP 를 부르는 쪽. JSON-RPC 2.0 over HTTP.

  ## 응답이 두 가지로 온다

  MCP 스트리머블 HTTP 는 같은 엔드포인트에서 `application/json` 또는
  `text/event-stream` 으로 답한다. 어느 쪽이 올지 서버가 정하므로 **둘 다 읽는다** —
  한쪽만 다루면 서버가 바꾸는 날 조용히 실패한다.

  ## 오류를 구분한다

  | 응답 | 뜻 | 우리가 할 일 |
  |---|---|---|
  | 401 | 토큰이 죽었다 | 갱신하거나, 안 되면 **재시도하지 않는다** |
  | `result.isError` | 도구가 거절했다 | 사용자에게 이유를 보여준다 |
  | 그 밖 | 일시적 | 워커가 재시도한다 |

  401 을 일시적 오류로 다루면 워커가 죽은 토큰으로 영원히 재시도한다.
  """

  require Logger

  @protocol "2025-06-18"

  @doc """
  도구를 부른다.

  `initialize` 를 매번 하지 않는다 — 상태 없는 HTTP 호출이라 세션을 잇지 않는다.
  칼라는 `tools/call` 을 바로 받는다.
  """
  def call_tool(url, access_token, name, args) do
    request(url, access_token, "tools/call", %{"name" => name, "arguments" => args})
  end

  @doc "쓸 수 있는 도구 목록. 진단용이다."
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

  # 스트림으로 오면 `data:` 줄을 모아 마지막 JSON 을 쓴다.
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
  도구 응답에서 텍스트를 뽑는다.

  MCP 도구는 `content: [%{type: "text", text: ...}]` 로 답한다. 칼라는 그 안에
  JSON 을 문자열로 담아 보내므로 한 겹 더 풀어야 한다.
  """
  def text_of(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  def text_of(_), do: ""

  @doc "도구 응답의 텍스트를 JSON 으로 푼다. JSON 이 아니면 그대로 돌려준다."
  def json_of(result) do
    text = text_of(result)

    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      _ -> text
    end
  end
end
