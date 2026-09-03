defmodule VRWeb.MCPControllerTest do
  @moduledoc """
  Our MCP server — the side where outsiders read the archive.

  **What is guarded here is isolation.** Whether the tools run matters less than
  whether other people's meetings leak. One leaked token exposes that account's
  entire archive, so we prove "permissions are re-evaluated" actually runs.
  """

  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.{MCP, Meetings}

  setup %{conn: conn} do
    owner = account_fixture()
    stranger = account_fixture()

    {:ok, meeting} = Meetings.create_meeting(owner, %{title: "My Meeting"})
    {:ok, others} = Meetings.create_meeting(stranger, %{title: "Someone Else's Meeting"})

    {:ok, token, _} = MCP.issue_token(owner.id, %{"name" => "test"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{conn: conn, owner: owner, meeting: meeting, others: others, token: token}
  end

  defp rpc(conn, method, params \\ %{}) do
    conn
    |> post(~p"/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    |> json_response(200)
  end

  defp tool(conn, name, args) do
    rpc(conn, "tools/call", %{"name" => name, "arguments" => args})
  end

  # Tools wrap results in a JSON string (MCP convention)
  defp payload(%{"result" => %{"content" => [%{"text" => text} | _]}}), do: Jason.decode!(text)

  defp error?(%{"result" => %{"isError" => true}}), do: true
  defp error?(_), do: false

  describe "authentication" do
    test "without a token, 401 plus how to authenticate", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post(~p"/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert conn.status == 401

      # RFC 9728 — the client learns how to authenticate from this
      assert [header] = get_resp_header(conn, "www-authenticate")
      assert header =~ "resource_metadata="
    end

    test "a revoked token is blocked immediately", %{conn: conn, owner: owner, token: token} do
      assert %{"result" => _} = rpc(conn, "ping")

      [issued] = MCP.list_tokens(owner.id)
      {:ok, _} = MCP.revoke_token(owner.id, issued.id)

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert conn.status == 401
    end

    test "metadata is readable without auth", %{conn: conn} do
      body =
        conn
        |> delete_req_header("authorization")
        |> get(~p"/.well-known/oauth-protected-resource/mcp")
        |> json_response(200)

      assert body["resource"] =~ "/mcp"
      assert body["bearer_methods_supported"] == ["header"]
    end
  end

  describe "isolation — someone else's meeting is as good as nonexistent" do
    test "cannot open someone else's meeting", %{conn: conn, others: others} do
      assert error?(tool(conn, "get_meeting", %{"meeting_id" => others.id}))
    end

    test "cannot read someone else's transcript", %{conn: conn, others: others} do
      assert error?(tool(conn, "get_transcript", %{"meeting_id" => others.id}))
    end

    test "the response is **identical** to a nonexistent meeting", %{conn: conn, others: others} do
      mine = tool(conn, "get_meeting", %{"meeting_id" => "meet_nonexistent"})
      theirs = tool(conn, "get_meeting", %{"meeting_id" => others.id})

      # Any distinction leaks the fact that the meeting exists
      assert mine["result"] == theirs["result"]
    end

    test "the list never mixes in someone else's meetings", %{conn: conn, others: others} do
      %{"meetings" => meetings} =
        payload(tool(conn, "list_meetings", %{"status" => "all", "limit" => 100}))

      refute Enum.any?(meetings, &(&1["id"] == others.id))
    end
  end

  describe "leak prevention" do
    test "internal fields are not provided", %{conn: conn, meeting: meeting} do
      data = payload(tool(conn, "get_meeting", %{"meeting_id" => meeting.id}))

      for field <- ~w(owner_id reviewer_id contributor_ids permissions
                      last_summary_error total_credits_charged) do
        refute Map.has_key?(data, field), "#{field} leaked"
      end
    end

    test "audio addresses are not provided", %{conn: conn, meeting: meeting, owner: owner} do
      {:ok, _session} = Meetings.create_session(meeting)

      data = payload(tool(conn, "get_meeting", %{"meeting_id" => meeting.id}))
      _ = owner

      for session <- data["recording_sessions"] || [] do
        refute Map.has_key?(session, "audio_href"), "audio address leaked"
        refute Map.has_key?(session, "credits_charged")
      end
    end
  end

  describe "tools" do
    test "advertises the three tools", %{conn: conn} do
      %{"result" => %{"tools" => tools}} = rpc(conn, "tools/list")

      assert Enum.map(tools, & &1["name"]) |> Enum.sort() ==
               ~w(get_meeting get_transcript list_meetings)
    end

    test "my own meeting opens", %{conn: conn, meeting: meeting} do
      data = payload(tool(conn, "get_meeting", %{"meeting_id" => meeting.id}))
      assert data["id"] == meeting.id
      assert data["title"] == "My Meeting"
    end

    test "rejects an unknown tool", %{conn: conn} do
      assert %{"error" => %{"code" => -32_602}} = tool(conn, "made_up_tool", %{})
    end

    test "rejects an unknown method", %{conn: conn} do
      assert %{"error" => %{"code" => -32_601}} = rpc(conn, "made_up_method")
    end
  end
end
