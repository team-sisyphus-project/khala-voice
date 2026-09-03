defmodule VRWeb.SpikeController do
  @moduledoc """
  Spike page for real-device verification.

  **Only available in the dev environment.** It requires no sign-in either —
  pushing a phone through the sign-in flow would blur what we're actually
  verifying (the recording itself).
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
