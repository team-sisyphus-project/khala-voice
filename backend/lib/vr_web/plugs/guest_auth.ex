defmodule VRWeb.GuestAuth do
  @moduledoc """
  Attaches the guest session to the `conn`.

  ## Why a header instead of a cookie

  The `:api` pipeline has no `protect_from_forgery`. Putting guest credentials
  in a cookie would open a CSRF surface. Cookies are also domain-wide, which
  conflicts with the "one meeting only" constraint. So we take the credential
  via the `X-Guest-Token` header, and the frontend keeps it in `sessionStorage`.

  ## This plug never rejects

  When there is no session it assigns `nil` and moves on. Rejection is each
  action's job via `guest_authorize/2` — so that "no token" and "no permission"
  produce identical responses.
  """

  import Plug.Conn

  alias VR.Sharing

  @header "x-guest-token"

  # Same pattern as `VRWeb.UserAuth` — the pipeline supplies the action name.
  # Used without a name, as in `plug VRWeb.GuestAuth`, it defaults to attach-only.
  def init([]), do: :fetch_current_guest
  def init(nil), do: :fetch_current_guest
  def init(action) when is_atom(action), do: action

  def call(conn, action) when is_atom(action) and not is_nil(action),
    do: apply(__MODULE__, action, [conn, []])

  def call(conn, _opts), do: fetch_current_guest(conn, [])

  @doc "Attaches the guest session when present. Passes through even without one."
  def fetch_current_guest(conn, _opts) do
    case get_req_header(conn, @header) do
      [token | _] ->
        case Sharing.fetch_live_guest(token) do
          {:ok, session} -> assign(conn, :current_guest, session)
          :error -> assign(conn, :current_guest, nil)
        end

      _ ->
        assign(conn, :current_guest, nil)
    end
  end

  @doc "Requires a guest session to pass. Responds 401 without one."
  def require_guest(conn, _opts) do
    conn =
      if Map.has_key?(conn.assigns, :current_guest), do: conn, else: fetch_current_guest(conn, [])

    if conn.assigns[:current_guest] do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        401,
        Jason.encode!(%{
          status: "error",
          code: "guest_session_required",
          message: "Please open the share link again"
        })
      )
      |> halt()
    end
  end
end
