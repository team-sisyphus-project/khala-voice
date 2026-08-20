defmodule VRWeb.SpikeController do
  @moduledoc """
  실기기 검증용 스파이크 페이지.

  **개발 환경에서만 열린다.** 로그인도 요구하지 않는다 —
  폰에서 로그인 흐름까지 태우면 검증하려는 것(녹음 자체)이 흐려진다.
  """

  use VRWeb, :controller

  plug :dev_only

  def recorder(conn, _params) do
    render(conn, :recorder, layout: false)
  end

  defp dev_only(conn, _opts) do
    if Application.get_env(:vr, :dev_routes, false) do
      conn
    else
      conn |> send_resp(404, "Not Found") |> halt()
    end
  end
end
