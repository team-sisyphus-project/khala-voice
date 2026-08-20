defmodule VRWeb.PageControllerTest do
  use VRWeb.ConnCase

  test "GET / 는 앱으로 보낸다", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/go/meetings"
  end

  test "GET / 비로그인은 결국 로그인 화면에 닿는다", %{conn: conn} do
    conn = conn |> get(~p"/") |> recycle() |> get("/go/meetings")
    assert redirected_to(conn) == ~p"/login"
  end
end
