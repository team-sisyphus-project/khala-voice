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

  test "GET /healthz 는 인증이나 데이터베이스 조회 없이 성공한다", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok"
  end

  test "로그인 전 화면의 기본 테마는 라이트다" do
    assert VRWeb.Layouts.theme(%{}) == "light"
  end
end
