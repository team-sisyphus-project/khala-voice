defmodule VRWeb.PageControllerTest do
  use VRWeb.ConnCase

  test "GET / sends you to the app", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/go/meetings"
  end

  test "GET / while unauthenticated eventually lands on login", %{conn: conn} do
    conn = conn |> get(~p"/") |> recycle() |> get("/go/meetings")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET /healthz succeeds without auth or database queries", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
  end

  test "pre-login screens default to the light theme" do
    assert VRWeb.Layouts.theme(%{}) == "light"
  end
end
