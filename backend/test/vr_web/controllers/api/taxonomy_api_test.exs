defmodule VRWeb.API.TaxonomyAPITest do
  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.{Accounts, Taxonomy}

  setup %{conn: conn} do
    account = account_fixture()
    other = account_fixture()
    {:ok, token, _} = Accounts.create_session(account)

    conn =
      conn
      |> Plug.Test.init_test_session(%{account_token: token})
      |> put_req_header("accept", "application/json")

    %{conn: conn, account: account, other: other}
  end

  describe "토픽" do
    test "만들고 목록에 나온다", %{conn: conn} do
      created =
        conn
        |> post(~p"/api/topics", %{"name" => "기획", "color" => "red"})
        |> json_response(201)

      assert created["name"] == "기획"
      assert created["color"] == "red"
      assert created["sort_order"] == 0
      # 소유자는 내보내지 않는다
      refute Map.has_key?(created, "owner_id")

      body = conn |> get(~p"/api/topics") |> json_response(200)
      assert [%{"name" => "기획", "meeting_count" => 0}] = body["topics"]
    end

    test "팔레트에 없는 색은 422", %{conn: conn} do
      conn = post(conn, ~p"/api/topics", %{"name" => "x", "color" => "hotpink"})
      assert json_response(conn, 422)["code"] == "validation_failed"
    end

    test "남의 토픽 수정은 404", %{conn: conn, other: other} do
      {:ok, topic} = Taxonomy.create_topic(other, %{"name" => "남의것"})

      # 403 이 아니다 — 그 id 의 존재를 노출하지 않는다
      assert conn |> patch(~p"/api/topics/#{topic.id}", %{"name" => "탈취"}) |> json_response(404)
      assert Taxonomy.get_topic(other.id, topic.id).name == "남의것"
    end

    test "남의 토픽 삭제는 404", %{conn: conn, other: other} do
      {:ok, topic} = Taxonomy.create_topic(other, %{"name" => "남의것"})

      assert conn |> delete(~p"/api/topics/#{topic.id}") |> json_response(404)
      assert Taxonomy.get_topic(other.id, topic.id)
    end

    test "없는 토픽도 404", %{conn: conn} do
      assert conn |> patch(~p"/api/topics/topc_없음", %{"name" => "x"}) |> json_response(404)
    end

    test "삭제하면 풀린 회의 수를 알려준다", %{conn: conn, account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "기획"})
      {:ok, _} = VR.Meetings.create_meeting(account, %{title: "a", topic_id: topic.id})

      body = conn |> delete(~p"/api/topics/#{topic.id}") |> json_response(200)
      assert body["detached_meetings"] == 1
    end

    test "reorder 가 :id 라우트로 새지 않는다", %{conn: conn, account: account} do
      {:ok, a} = Taxonomy.create_topic(account, %{"name" => "A"})
      {:ok, b} = Taxonomy.create_topic(account, %{"name" => "B"})

      body =
        conn
        |> patch(~p"/api/topics/reorder", %{"ids" => [b.id, a.id]})
        |> json_response(200)

      assert Enum.map(body["topics"], & &1["id"]) == [b.id, a.id]
    end

    test "reorder 에 ids 가 없으면 422", %{conn: conn} do
      assert conn |> patch(~p"/api/topics/reorder", %{}) |> json_response(422)
    end
  end

  describe "라벨" do
    test "만들고 지운다", %{conn: conn} do
      created = conn |> post(~p"/api/labels", %{"name" => "긴급"}) |> json_response(201)
      assert created["color"] == "blue"

      assert conn |> delete(~p"/api/labels/#{created["id"]}") |> json_response(200)
      assert conn |> get(~p"/api/labels") |> json_response(200) |> Map.get("labels") == []
    end

    test "남의 라벨은 404", %{conn: conn, other: other} do
      {:ok, label} = Taxonomy.create_label(other, %{"name" => "남의것"})
      assert conn |> delete(~p"/api/labels/#{label.id}") |> json_response(404)
    end
  end

  describe "인증" do
    test "비로그인은 401 JSON" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> put_req_header("accept", "application/json")

      assert conn |> get(~p"/api/topics") |> json_response(401)
    end
  end
end
