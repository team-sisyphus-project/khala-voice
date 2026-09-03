defmodule VRWeb.MCPController do
  @moduledoc """
  Our MCP server. JSON-RPC 2.0 over HTTP.

  External AIs and agents **read the archive**. Design: `docs/15-mcp-khala.md`.

  ## The server decides permissions here too

  MCP is no exception. After identifying which account a token belongs to,
  requests go through `VR.Meetings.authorize/4` as that account, unchanged.
  **No access means 404** — a missing meeting and a meeting without permission
  get the same answer.

  ## No audio is served

  Text is enough for meeting content, and voices are personal data in
  themselves — not something to stream out on the strength of a single token.
  `Redact.meeting(audio: :drop)`.
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
      Searches for meetings in the archive, using the same filters as the UI.
      Results include the summary and classification; fetch the raw transcript
      separately with get_transcript.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          q: %{type: "string", description: "Text to search for in title, description, and summary"},
          status: %{
            type: "string",
            enum: ["all", "active", "completed", "archived"],
            description: "Defaults to archived — archived meetings only"
          },
          topic_id: %{type: "string"},
          label_ids: %{type: "array", items: %{type: "string"}},
          from: %{type: "string", description: "ISO8601. On or after this time"},
          to: %{type: "string", description: "ISO8601. On or before this time"},
          limit: %{type: "integer", description: "Default 20, max 100"}
        }
      }
    },
    %{
      name: "get_meeting",
      description: "A single meeting. Summary, classification, and session list.",
      inputSchema: %{
        type: "object",
        properties: %{meeting_id: %{type: "string"}},
        required: ["meeting_id"]
      }
    },
    %{
      name: "get_transcript",
      description: "Raw transcript (Markdown), with speaker names already applied.",
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

  # Notifications (requests without an id) get no response — per the JSON-RPC spec.
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
    do: {:error, -32_601, "Unknown method: #{method}"}

  # ── Tools ───────────────────────────────────────────────

  defp call_tool("list_meetings", args, account) do
    opts = [
      q: args["q"],
      # Archived by default — natural for a tool that reads the archive.
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
    # `authorize/4` re-checks permissions. Missing or unauthorized both yield :not_found.
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
          ok(%{markdown: nil, reason: "No transcript available yet"})
        end

      {:error, _} ->
        not_found()
    end
  end

  defp call_tool(name, _args, _account) when is_binary(name),
    do: {:error, -32_602, "Unknown tool: #{name}"}

  defp call_tool(_, _, _), do: {:error, -32_602, "Missing tool name"}

  # ── Responses ───────────────────────────────────────────

  # MCP tools respond with `content: [{type: "text", text: ...}]`.
  defp ok(data) do
    {:ok, %{content: [%{type: "text", text: Jason.encode!(data)}]}}
  end

  # **404 is emitted as a tool error.** Missing meetings and unauthorized meetings are indistinguishable.
  defp not_found do
    {:ok, %{isError: true, content: [%{type: "text", text: "Not found"}]}}
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
