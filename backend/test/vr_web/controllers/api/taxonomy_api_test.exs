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

  describe "topics" do
    test "creates and appears in the list", %{conn: conn} do
      created =
        conn
        |> post(~p"/api/topics", %{"name" => "Planning", "color" => "red"})
        |> json_response(201)

      assert created["name"] == "Planning"
      assert created["color"] == "red"
      assert created["sort_order"] == 0
      # The owner is not exported
      refute Map.has_key?(created, "owner_id")

      body = conn |> get(~p"/api/topics") |> json_response(200)
      assert [%{"name" => "Planning", "meeting_count" => 0}] = body["topics"]
    end

    test "colors outside the palette are 422", %{conn: conn} do
      conn = post(conn, ~p"/api/topics", %{"name" => "x", "color" => "hotpink"})
      assert json_response(conn, 422)["code"] == "validation_failed"
    end

    test "editing someone else's topic is 404", %{conn: conn, other: other} do
      {:ok, topic} = Taxonomy.create_topic(other, %{"name" => "Theirs"})

      # Not 403 — do not reveal that the id exists
      assert conn |> patch(~p"/api/topics/#{topic.id}", %{"name" => "hijacked"}) |> json_response(404)
      assert Taxonomy.get_topic(other.id, topic.id).name == "Theirs"
    end

    test "deleting someone else's topic is 404", %{conn: conn, other: other} do
      {:ok, topic} = Taxonomy.create_topic(other, %{"name" => "Theirs"})

      assert conn |> delete(~p"/api/topics/#{topic.id}") |> json_response(404)
      assert Taxonomy.get_topic(other.id, topic.id)
    end

    test "a nonexistent topic is also 404", %{conn: conn} do
      assert conn |> patch(~p"/api/topics/topc_missing", %{"name" => "x"}) |> json_response(404)
    end

    test "deletion reports how many meetings were detached", %{conn: conn, account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      {:ok, _} = VR.Meetings.create_meeting(account, %{title: "a", topic_id: topic.id})

      body = conn |> delete(~p"/api/topics/#{topic.id}") |> json_response(200)
      assert body["detached_meetings"] == 1
    end

    test "reorder does not leak into the :id route", %{conn: conn, account: account} do
      {:ok, a} = Taxonomy.create_topic(account, %{"name" => "A"})
      {:ok, b} = Taxonomy.create_topic(account, %{"name" => "B"})

      body =
        conn
        |> patch(~p"/api/topics/reorder", %{"ids" => [b.id, a.id]})
        |> json_response(200)

      assert Enum.map(body["topics"], & &1["id"]) == [b.id, a.id]
    end

    test "reorder without ids is 422", %{conn: conn} do
      assert conn |> patch(~p"/api/topics/reorder", %{}) |> json_response(422)
    end
  end

  describe "labels" do
    test "creates and deletes", %{conn: conn} do
      created = conn |> post(~p"/api/labels", %{"name" => "Urgent"}) |> json_response(201)
      assert created["color"] == "blue"

      assert conn |> delete(~p"/api/labels/#{created["id"]}") |> json_response(200)
      assert conn |> get(~p"/api/labels") |> json_response(200) |> Map.get("labels") == []
    end

    test "someone else's label is 404", %{conn: conn, other: other} do
      {:ok, label} = Taxonomy.create_label(other, %{"name" => "Theirs"})
      assert conn |> delete(~p"/api/labels/#{label.id}") |> json_response(404)
    end
  end

  describe "authentication" do
    test "unauthenticated gets 401 JSON" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> put_req_header("accept", "application/json")

      assert conn |> get(~p"/api/topics") |> json_response(401)
    end
  end
end
