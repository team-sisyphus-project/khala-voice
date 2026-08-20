defmodule VRWeb.MCPController do
  @moduledoc """
  우리 MCP 서버. JSON-RPC 2.0 over HTTP.

  외부 AI·에이전트가 **아카이브를 읽는다**. 설계는 `docs/15-mcp-khala.md`.

  ## 권한은 여기서도 서버가 판정한다

  MCP 라고 예외가 아니다. 토큰이 어느 계정의 것인지 확인한 뒤,
  그 계정으로 `VR.Meetings.authorize/4` 를 그대로 통과시킨다.
  **접근 불가는 404** — 없는 회의든 권한 없는 회의든 같은 답을 준다.

  ## 오디오는 주지 않는다

  회의록 내용은 텍스트로 충분하고, 음성은 목소리 자체가 개인정보라
  토큰 하나로 흘려보낼 것이 아니다. `Redact.meeting(audio: :drop)`.
  """

  use VRWeb, :controller

  alias VR.Meetings
  alias VR.Meetings.{Export, Redact}
  alias VRWeb.API.JSONView

  @protocol "2025-06-18"

  @tools [
    %{
      name: "list_meetings",
      description: """
      아카이브에서 회의를 찾는다. 화면의 필터와 같은 조건을 쓴다.
      결과에는 요약과 분류가 들어 있고, 전사 원문은 get_transcript 로 따로 받는다.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          q: %{type: "string", description: "제목·설명·요약에서 찾을 말"},
          status: %{
            type: "string",
            enum: ["all", "active", "completed", "archived"],
            description: "기본은 archived — 보관된 회의만"
          },
          topic_id: %{type: "string"},
          label_ids: %{type: "array", items: %{type: "string"}},
          from: %{type: "string", description: "ISO8601. 이 시각 이후"},
          to: %{type: "string", description: "ISO8601. 이 시각 이전"},
          limit: %{type: "integer", description: "기본 20, 최대 100"}
        }
      }
    },
    %{
      name: "get_meeting",
      description: "회의 하나. 요약 · 분류 · 세션 목록.",
      inputSchema: %{
        type: "object",
        properties: %{meeting_id: %{type: "string"}},
        required: ["meeting_id"]
      }
    },
    %{
      name: "get_transcript",
      description: "전사 원문 (마크다운). 화자 이름이 적용된 상태로 준다.",
      inputSchema: %{
        type: "object",
        properties: %{meeting_id: %{type: "string"}},
        required: ["meeting_id"]
      }
    }
  ]

  def handle(conn, %{"method" => method} = params) do
    account = conn.assigns.mcp_account
    id = params["id"]

    case dispatch(method, params["params"] || %{}, account) do
      {:ok, result} ->
        json(conn, %{jsonrpc: "2.0", id: id, result: result})

      {:error, code, message} ->
        json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
    end
  end

  # 알림(id 없는 요청)은 답하지 않는다 — JSON-RPC 규약이다.
  def handle(conn, _params), do: send_resp(conn, :accepted, "")

  defp dispatch("initialize", _params, _account) do
    {:ok,
     %{
       protocolVersion: @protocol,
       capabilities: %{tools: %{}},
       serverInfo: %{name: "KHALA VOICE", version: "1"}
     }}
  end

  defp dispatch("tools/list", _params, _account), do: {:ok, %{tools: @tools}}

  defp dispatch("tools/call", %{"name" => name} = params, account) do
    call_tool(name, params["arguments"] || %{}, account)
  end

  defp dispatch("ping", _params, _account), do: {:ok, %{}}

  defp dispatch(method, _params, _account),
    do: {:error, -32_601, "알 수 없는 메서드: #{method}"}

  # ── 도구 ────────────────────────────────────────────────

  defp call_tool("list_meetings", args, account) do
    opts = [
      q: args["q"],
      # 기본은 보관본이다. 아카이브를 읽는 도구라 그게 자연스럽다.
      status: args["status"] || "archived",
      topic_id: args["topic_id"],
      label_ids: args["label_ids"],
      from: parse_time(args["from"]),
      to: parse_time(args["to"]),
      limit: limit(args["limit"])
    ]

    meetings = Meetings.list_meetings(account, opts)

    payload =
      Enum.map(meetings, fn meeting ->
        meeting
        |> JSONView.meeting(Meetings.level(meeting, account))
        |> Redact.meeting(audio: :drop)
      end)

    ok(%{meetings: payload, count: length(payload)})
  end

  defp call_tool("get_meeting", %{"meeting_id" => id}, account) do
    # `authorize/4` 가 권한을 다시 판정한다. 없거나 권한이 없으면 둘 다 :not_found.
    case Meetings.authorize(id, account, :lv2) do
      {:ok, meeting, level} ->
        meeting
        |> JSONView.meeting(level)
        |> Redact.meeting(audio: :drop)
        |> ok()

      {:error, _} ->
        not_found()
    end
  end

  defp call_tool("get_transcript", %{"meeting_id" => id}, account) do
    case Meetings.authorize(id, account, :lv2) do
      {:ok, meeting, _level} ->
        sessions = Meetings.list_sessions(meeting.id)

        if Export.exportable?(meeting, sessions) do
          ok(%{markdown: Export.to_markdown(meeting, sessions)})
        else
          ok(%{markdown: nil, reason: "전사가 아직 없습니다"})
        end

      {:error, _} ->
        not_found()
    end
  end

  defp call_tool(name, _args, _account) when is_binary(name),
    do: {:error, -32_602, "알 수 없는 도구: #{name}"}

  defp call_tool(_, _, _), do: {:error, -32_602, "도구 이름이 없습니다"}

  # ── 응답 ────────────────────────────────────────────────

  # MCP 도구는 `content: [{type: "text", text: ...}]` 로 답한다.
  defp ok(data) do
    {:ok, %{content: [%{type: "text", text: Jason.encode!(data)}]}}
  end

  # **404 를 도구 오류로 낸다.** 없는 회의와 권한 없는 회의를 구분하지 않는다.
  defp not_found do
    {:ok, %{isError: true, content: [%{type: "text", text: "찾을 수 없습니다"}]}}
  end

  defp limit(n) when is_integer(n) and n > 0, do: min(n, 100)
  defp limit(_), do: 20

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
