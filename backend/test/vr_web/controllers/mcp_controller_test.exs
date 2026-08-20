defmodule VRWeb.MCPControllerTest do
  @moduledoc """
  우리 MCP 서버 — 외부가 아카이브를 읽는 쪽.

  **여기서 지키는 것은 격리다.** 도구가 도는지보다, 남의 회의가 새지 않는지가
  중요하다. 토큰 하나가 새면 그 계정의 아카이브 전부가 새는 구조라
  "권한을 다시 판정한다"가 실제로 도는지 증명해 둔다.
  """

  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.{MCP, Meetings}

  setup %{conn: conn} do
    owner = account_fixture()
    stranger = account_fixture()

    {:ok, meeting} = Meetings.create_meeting(owner, %{title: "내 회의"})
    {:ok, others} = Meetings.create_meeting(stranger, %{title: "남의 회의"})

    {:ok, token, _} = MCP.issue_token(owner.id, %{"name" => "테스트"})

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

  # 도구는 결과를 JSON 문자열로 감싸 돌려준다 (MCP 규약)
  defp payload(%{"result" => %{"content" => [%{"text" => text} | _]}}), do: Jason.decode!(text)

  defp error?(%{"result" => %{"isError" => true}}), do: true
  defp error?(_), do: false

  describe "인증" do
    test "토큰이 없으면 401 과 함께 인증 방법을 알린다", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post(~p"/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      assert conn.status == 401

      # RFC 9728 — 클라이언트가 이걸 보고 어떻게 인증할지 알아낸다
      assert [header] = get_resp_header(conn, "www-authenticate")
      assert header =~ "resource_metadata="
    end

    test "취소한 토큰은 즉시 막힌다", %{conn: conn, owner: owner, token: token} do
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

    test "메타데이터는 인증 없이 읽힌다", %{conn: conn} do
      body =
        conn
        |> delete_req_header("authorization")
        |> get(~p"/.well-known/oauth-protected-resource/mcp")
        |> json_response(200)

      assert body["resource"] =~ "/mcp"
      assert body["bearer_methods_supported"] == ["header"]
    end
  end

  describe "격리 — 남의 회의는 없는 것과 같다" do
    test "남의 회의를 열 수 없다", %{conn: conn, others: others} do
      assert error?(tool(conn, "get_meeting", %{"meeting_id" => others.id}))
    end

    test "남의 전사를 읽을 수 없다", %{conn: conn, others: others} do
      assert error?(tool(conn, "get_transcript", %{"meeting_id" => others.id}))
    end

    test "없는 회의와 **같은 응답**이다", %{conn: conn, others: others} do
      mine = tool(conn, "get_meeting", %{"meeting_id" => "meet_nonexistent"})
      theirs = tool(conn, "get_meeting", %{"meeting_id" => others.id})

      # 구분되면 "그 회의는 있다"는 사실이 새어 나간다
      assert mine["result"] == theirs["result"]
    end

    test "목록에 남의 회의가 섞이지 않는다", %{conn: conn, others: others} do
      %{"meetings" => meetings} =
        payload(tool(conn, "list_meetings", %{"status" => "all", "limit" => 100}))

      refute Enum.any?(meetings, &(&1["id"] == others.id))
    end
  end

  describe "유출 방지" do
    test "내부 필드를 주지 않는다", %{conn: conn, meeting: meeting} do
      data = payload(tool(conn, "get_meeting", %{"meeting_id" => meeting.id}))

      for field <- ~w(owner_id reviewer_id contributor_ids permissions
                      last_summary_error total_credits_charged) do
        refute Map.has_key?(data, field), "#{field} 가 새어 나갔다"
      end
    end

    test "오디오 주소를 주지 않는다", %{conn: conn, meeting: meeting, owner: owner} do
      {:ok, _session} = Meetings.create_session(meeting)

      data = payload(tool(conn, "get_meeting", %{"meeting_id" => meeting.id}))
      _ = owner

      for session <- data["recording_sessions"] || [] do
        refute Map.has_key?(session, "audio_href"), "오디오 주소가 새어 나갔다"
        refute Map.has_key?(session, "credits_charged")
      end
    end
  end

  describe "도구" do
    test "세 가지를 알린다", %{conn: conn} do
      %{"result" => %{"tools" => tools}} = rpc(conn, "tools/list")

      assert Enum.map(tools, & &1["name"]) |> Enum.sort() ==
               ~w(get_meeting get_transcript list_meetings)
    end

    test "내 회의는 열린다", %{conn: conn, meeting: meeting} do
      data = payload(tool(conn, "get_meeting", %{"meeting_id" => meeting.id}))
      assert data["id"] == meeting.id
      assert data["title"] == "내 회의"
    end

    test "알 수 없는 도구는 거절한다", %{conn: conn} do
      assert %{"error" => %{"code" => -32_602}} = tool(conn, "지어낸도구", %{})
    end

    test "알 수 없는 메서드는 거절한다", %{conn: conn} do
      assert %{"error" => %{"code" => -32_601}} = rpc(conn, "지어낸메서드")
    end
  end
end
