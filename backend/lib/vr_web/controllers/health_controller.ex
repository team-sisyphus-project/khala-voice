defmodule VRWeb.HealthController do
  use VRWeb, :controller

  def show(conn, _params) do
    text(conn, "ok")
  end
end
