defmodule VR.Khala.OAuth do
  @moduledoc """
  Khala OAuth 2.0 — **a PKCE public client**.

  ## Why there is no client_secret

  Khala advertises `token_endpoint_auth_methods_supported: ["none"]`.
  It is a public client, so no secret exists at all — PKCE (S256) takes its place.

  This repo is published as open source and **keeps no secrets in code** (`CLAUDE.md`).
  Since this flow has no secret to begin with, it does not conflict with that rule.

  ## Why we do not hardcode a client_id

  A `registration_endpoint` exists, so **dynamic client registration** (RFC 7591)
  works. We do not have to pre-register every deployment domain ourselves, and
  when the domain changes we simply register again.

  ## We do not write endpoints into code

  They come from `/.well-known/oauth-authorization-server`. If Khala moves a
  path, we have nothing to fix — hardcoding it means silent failure the day it drifts.
  """

  require Logger

  alias VR.Config

  @discovery_path "/.well-known/oauth-authorization-server"
  @scope "khala"

  @doc """
  The Khala MCP URL. `nil` when not configured — **no literal defaults** (`CLAUDE.md`).
  """
  def mcp_url, do: Config.fetch("khala.mcp_url")

  @doc "Whether to expose the integration in the UI."
  def enabled?, do: Config.fetch("khala.enabled") in [true, "true"]

  @doc """
  Authorization server metadata. Fetched every time — caching means we would not
  notice when Khala changes it.

  Looked up at the **origin** of the MCP URL (`https://mcp.khala.to/mcp`).
  """
  def discover do
    with {:ok, origin} <- origin(),
         {:ok, %{status: 200, body: body}} when is_map(body) <-
           Req.get(origin <> @discovery_path, receive_timeout: 15_000) do
      {:ok, body}
    else
      {:ok, %{status: status}} -> {:error, {:discovery_failed, status}}
      {:error, reason} -> {:error, reason}
      :error -> {:error, :not_configured}
    end
  end

  @doc """
  Dynamic client registration. Returns the `client_id`.

  `redirect_uri` is **our callback URL**. Khala will only redirect back to this
  value, so the one registered and the one used in the authorization request
  must match.
  """
  def register_client(meta, redirect_uri) do
    endpoint = meta["registration_endpoint"]

    if is_binary(endpoint) do
      body = %{
        "client_name" => "KHALA VOICE",
        "redirect_uris" => [redirect_uri],
        "grant_types" => ["authorization_code"],
        "response_types" => ["code"],
        # Public client — we accept no secret
        "token_endpoint_auth_method" => "none"
      }

      case Req.post(endpoint, json: body, receive_timeout: 15_000) do
        {:ok, %{status: status, body: %{"client_id" => id}}} when status in 200..201 ->
          {:ok, id}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("[Khala] client registration failed #{status}: #{inspect(body)}")
          {:error, {:register_failed, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_registration_endpoint}
    end
  end

  @doc """
  PKCE verifier and challenge.

  The verifier is kept in the session and sent as is at token exchange. **This
  is what replaces the client_secret** — intercepting the authorization code is
  useless without the verifier.
  """
  def pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    {verifier, challenge}
  end

  @doc "The authorization URL to send the user to."
  def authorize_url(meta, client_id, redirect_uri, challenge, state) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "scope" => @scope,
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        # Which resource the token is for (RFC 8707) — MCP checks this
        "resource" => mcp_url()
      })

    meta["authorization_endpoint"] <> "?" <> query
  end

  @doc "Exchange an authorization code for tokens."
  def exchange(meta, client_id, code, verifier, redirect_uri) do
    post_token(meta, %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => client_id,
      "code_verifier" => verifier,
      "resource" => mcp_url()
    })
  end

  @doc "Refresh an expired token."
  def refresh(meta, client_id, refresh_token) do
    post_token(meta, %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => client_id,
      "resource" => mcp_url()
    })
  end

  defp post_token(meta, form) do
    case Req.post(meta["token_endpoint"], form: form, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}} ->
        {:ok,
         %{
           access_token: token,
           refresh_token: body["refresh_token"],
           expires_at: expires_at(body["expires_in"])
         }}

      {:ok, %{status: status, body: body}} ->
        # Never log tokens. Only the error code goes to the log.
        Logger.warning("[Khala] token request failed #{status}: #{inspect(body["error"])}")
        {:error, {:token_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expires_at(seconds) when is_integer(seconds) and seconds > 0,
    do: DateTime.utc_now(:second) |> DateTime.add(seconds, :second)

  defp expires_at(_), do: nil

  defp origin do
    case mcp_url() do
      url when is_binary(url) ->
        uri = URI.parse(url)
        {:ok, "#{uri.scheme}://#{uri.host}#{port(uri)}"}

      _ ->
        :error
    end
  end

  defp port(%URI{port: nil}), do: ""
  defp port(%URI{scheme: "https", port: 443}), do: ""
  defp port(%URI{scheme: "http", port: 80}), do: ""
  defp port(%URI{port: p}), do: ":#{p}"
end
