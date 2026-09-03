defmodule VRWeb.KhalaController do
  @moduledoc """
  Khala account linking — OAuth 2.0 authorization code flow (PKCE).

  Only the browser round-trip lives here. Using the tokens is `VR.Khala`'s job.

  ## What goes in the session

  The PKCE verifier and `state` are stored in the session. **The session, not a
  cookie** — if the verifier leaks, PKCE no longer protects anything.

  `state` is the CSRF defense. If the value that comes back on the callback
  differs from the one we sent, someone is trying to link our user to somebody
  else's authorization code.
  """

  use VRWeb, :controller

  require Logger

  alias VR.Khala
  alias VR.Khala.OAuth

  @doc "Redirects to the Khala sign-in page."
  def connect(conn, _params) do
    redirect_uri = callback_url(conn)

    with true <- OAuth.enabled?() || :disabled,
         {:ok, meta} <- OAuth.discover(),
         {:ok, client_id} <- OAuth.register_client(meta, redirect_uri) do
      {verifier, challenge} = OAuth.pkce()
      state = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      conn
      |> put_session(:khala_verifier, verifier)
      |> put_session(:khala_state, state)
      |> put_session(:khala_client_id, client_id)
      |> redirect(external: OAuth.authorize_url(meta, client_id, redirect_uri, challenge, state))
    else
      :disabled ->
        conn |> put_flash(:error, "Khala integration is disabled") |> redirect(to: "/go/settings")

      {:error, reason} ->
        Logger.warning("[Khala] failed to start connection: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Could not connect to Khala")
        |> redirect(to: "/go/settings")
    end
  end

  @doc "Handles the redirect back from Khala."
  def callback(conn, params) do
    account = conn.assigns.current_account
    expected = get_session(conn, :khala_state)
    verifier = get_session(conn, :khala_verifier)
    client_id = get_session(conn, :khala_client_id)

    conn = clear_khala_session(conn)

    cond do
      params["error"] ->
        # The user may simply have declined. Don't alarm them with an error.
        conn |> put_flash(:info, "Khala connection was cancelled") |> redirect(to: "/go/settings")

      is_nil(expected) or params["state"] != expected ->
        # A callback we did not initiate
        conn |> put_flash(:error, "The connection request has expired") |> redirect(to: "/go/settings")

      is_nil(params["code"]) or is_nil(verifier) or is_nil(client_id) ->
        conn |> put_flash(:error, "Could not connect to Khala") |> redirect(to: "/go/settings")

      true ->
        finish(conn, account, client_id, params["code"], verifier)
    end
  end

  defp finish(conn, account, client_id, code, verifier) do
    with {:ok, meta} <- OAuth.discover(),
         {:ok, tokens} <- OAuth.exchange(meta, client_id, code, verifier, callback_url(conn)),
         {:ok, _connection} <- Khala.connect(account.id, client_id, tokens) do
      # The inbox could be created on first send, but creating it here lets the
      # settings screen show "Connected · inbox name" right away. The connection
      # remains valid even if this fails.
      _ = Khala.ensure_inbox(account.id)

      conn |> put_flash(:info, "Connected to Khala") |> redirect(to: "/go/settings")
    else
      {:error, reason} ->
        Logger.warning("[Khala] token exchange failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Could not connect to Khala")
        |> redirect(to: "/go/settings")
    end
  end

  defp clear_khala_session(conn) do
    conn
    |> delete_session(:khala_verifier)
    |> delete_session(:khala_state)
    |> delete_session(:khala_client_id)
  end

  # The URL registered with Khala and the one used in the authorization request **must match**.
  defp callback_url(_conn), do: url(~p"/khala/callback")
end
