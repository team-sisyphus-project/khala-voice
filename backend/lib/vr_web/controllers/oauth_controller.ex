defmodule VRWeb.OAuthController do
  @moduledoc """
  Social sign-in entry point and callback.

  **Disabled providers respond with 404.** Turning one off in the admin makes
  the route look as if it does not exist at all.
  """

  use VRWeb, :controller

  alias VR.Accounts
  alias VR.Auth.{OAuth, Providers}
  alias VRWeb.UserAuth

  require Logger

  def request(conn, %{"provider" => provider}) do
    with true <- OAuth.supported?(provider),
         config when not is_nil(config) <- Providers.get(provider),
         true <- config.active,
         true <- is_binary(config.resolved_redirect_uri) do
      state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      conn
      |> put_session(:oauth_state, state)
      |> put_session(:oauth_provider, provider)
      |> redirect(external: OAuth.authorize_url(provider, config, state))
    else
      _ -> not_found(conn)
    end
  end

  def callback(conn, %{"provider" => provider, "code" => code, "state" => state}) do
    expected = get_session(conn, :oauth_state)
    expected_provider = get_session(conn, :oauth_provider)

    conn = conn |> delete_session(:oauth_state) |> delete_session(:oauth_provider)

    cond do
      not OAuth.supported?(provider) ->
        not_found(conn)

      is_nil(expected) or not secure_compare(state, expected) or expected_provider != provider ->
        # state mismatch = CSRF attempt or expired session
        fail(conn, "The authentication request is invalid. Please try again.")

      true ->
        config = Providers.get(provider)

        if config && config.active do
          complete(conn, provider, config, code)
        else
          not_found(conn)
        end
    end
  end

  # The user cancelled on the provider's screen
  def callback(conn, %{"provider" => _provider}) do
    fail(conn, "Social sign-in was cancelled")
  end

  defp complete(conn, provider, config, code) do
    case OAuth.fetch_profile(provider, config, code) do
      {:ok, %{provider_id: provider_id, email: email} = profile} when is_binary(email) ->
        case Accounts.find_or_create_social_account(provider, provider_id, %{
               email: email,
               name: profile[:name]
             }) do
          {:ok, account} ->
            Accounts.record_login_attempt(email, client_ip(conn), true)
            UserAuth.log_in_account(conn, account)

          {:error, changeset} ->
            Logger.warning("[OAuth] account creation failed: #{inspect(changeset.errors)}")
            fail(conn, "Could not create the account. This email may already be registered with a different sign-in method.")
        end

      {:ok, _profile} ->
        # Without an email we cannot identify the account
        fail(conn, "Could not retrieve your email address. Please allow email sharing on the provider.")

      {:error, reason} ->
        Logger.warning("[OAuth] profile fetch failed: #{provider} #{inspect(reason)}")
        fail(conn, "Social sign-in failed. Please try again later.")
    end
  end

  defp fail(conn, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/login")
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> text("Not Found") |> halt()
  end

  # Constant-time comparison to avoid timing attacks
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_compare(_a, _b), do: false

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
