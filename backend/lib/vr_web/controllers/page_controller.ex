defmodule VRWeb.PageController do
  use VRWeb, :controller

  @doc """
  The root (`/`) redirects into the app.

  `/go` is a **surface-neutral** prefix — whether it means desktop (`/app`) or
  mobile (`/m`) is decided by the browser (`apps/web/src/lib/surface.ts`).
  The server does not know the viewport width.

  There is no landing page — this service is used signed-in, and the repo's
  README does the introducing. This is where the default Phoenix template
  used to sit.

  If the user is not signed in, `:require_auth` on `/go/meetings` sends them
  back to `/login`. So we do not check the sign-in state here — that decision
  lives in exactly one place (the plug).
  """
  def home(conn, _params) do
    redirect(conn, to: "/go/meetings")
  end
end
