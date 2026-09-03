defmodule VR.Auth.OAuth do
  @moduledoc """
  OAuth 2.0 Authorization Code flow.

  Only the per-provider endpoints are known here; keys and enablement are decided by
  `VR.Auth.Providers` (DB). Why no library: the provider list and keys must change
  **at runtime from the DB**, while most OAuth libraries assume compile-time configuration.

  ## CSRF

  A random value goes into `state`, the same value is kept in the session, and the two
  are compared at the callback. A mismatch is rejected. Without this, an attacker could
  attach their own account to the victim's session.
  """

  require Logger

  @providers %{
    "google" => %{
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      userinfo_url: "https://www.googleapis.com/oauth2/v3/userinfo",
      default_scopes: ["openid", "email", "profile"],
      extra_authorize_params: %{"access_type" => "online", "prompt" => "select_account"}
    },
    "github" => %{
      authorize_url: "https://github.com/login/oauth/authorize",
      token_url: "https://github.com/login/oauth/access_token",
      userinfo_url: "https://api.github.com/user",
      default_scopes: ["read:user", "user:email"],
      extra_authorize_params: %{}
    }
  }

  def supported?(provider), do: Map.has_key?(@providers, provider)

  @doc "Builds the provider's authorization page URL."
  def authorize_url(provider, config, state) do
    spec = Map.fetch!(@providers, provider)

    params =
      Map.merge(spec.extra_authorize_params, %{
        "client_id" => config.resolved_client_id,
        "redirect_uri" => config.resolved_redirect_uri,
        "response_type" => "code",
        "scope" => Enum.join(scopes(config, spec), " "),
        "state" => state
      })

    spec.authorize_url <> "?" <> URI.encode_query(params)
  end

  @doc """
  Exchanges an authorization code for a profile.

  `{:ok, %{provider_id, email, name}}` or `{:error, reason}`.
  """
  def fetch_profile(provider, config, code) do
    spec = Map.fetch!(@providers, provider)

    with {:ok, access_token} <- exchange_code(spec, config, code),
         {:ok, raw} <- fetch_userinfo(provider, spec, access_token) do
      normalize(provider, raw)
    end
  end

  # ── Internal ─────────────────────────────────────────────

  defp scopes(%{scopes: scopes}, _spec) when is_list(scopes) and scopes != [], do: scopes
  defp scopes(_config, spec), do: spec.default_scopes

  defp exchange_code(spec, config, code) do
    body = %{
      "client_id" => config.resolved_client_id,
      "client_secret" => config.resolved_client_secret,
      "code" => code,
      "grant_type" => "authorization_code",
      "redirect_uri" => config.resolved_redirect_uri
    }

    case Req.post(spec.token_url,
           form: body,
           headers: [{"accept", "application/json"}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        # The response body may contain tokens, so never log it in full
        Logger.warning("[OAuth] Token exchange failed: status=#{status} error=#{inspect(body["error"])}")
        {:error, :token_exchange_failed}

      {:error, reason} ->
        Logger.warning("[OAuth] Token request failed: #{inspect(reason)}")
        {:error, :token_request_failed}
    end
  end

  defp fetch_userinfo("github", spec, access_token) do
    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "voice-recording"}
    ]

    with {:ok, %{status: 200, body: user}} <-
           Req.get(spec.userinfo_url, headers: headers, receive_timeout: 15_000) do
      # GitHub profiles may have no email (privacy setting). Fetch it from a separate endpoint.
      email = user["email"] || primary_github_email(headers)
      {:ok, Map.put(user, "email", email)}
    else
      _ -> {:error, :userinfo_failed}
    end
  end

  defp fetch_userinfo(_provider, spec, access_token) do
    case Req.get(spec.userinfo_url,
           headers: [{"authorization", "Bearer #{access_token}"}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      _ -> {:error, :userinfo_failed}
    end
  end

  defp primary_github_email(headers) do
    case Req.get("https://api.github.com/user/emails", headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: emails}} when is_list(emails) ->
        primary =
          Enum.find(emails, &(&1["primary"] && &1["verified"])) ||
            Enum.find(emails, & &1["verified"])

        primary && primary["email"]

      _ ->
        nil
    end
  end

  defp normalize("google", raw) do
    case raw["sub"] do
      nil -> {:error, :missing_provider_id}
      sub -> {:ok, %{provider_id: to_string(sub), email: raw["email"], name: raw["name"]}}
    end
  end

  defp normalize("github", raw) do
    case raw["id"] do
      nil ->
        {:error, :missing_provider_id}

      id ->
        {:ok,
         %{
           provider_id: to_string(id),
           email: raw["email"],
           name: raw["name"] || raw["login"]
         }}
    end
  end
end
