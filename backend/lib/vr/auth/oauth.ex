defmodule VR.Auth.OAuth do
  @moduledoc """
  OAuth 2.0 Authorization Code 흐름.

  제공자별 엔드포인트만 여기서 알고, 키·활성화 여부는 `VR.Auth.Providers`(DB)가 정한다.
  라이브러리를 쓰지 않는 이유: 제공자 목록과 키를 **런타임에 DB에서** 바꿔야 하는데
  대부분의 OAuth 라이브러리는 컴파일 타임 설정을 전제로 한다.

  ## CSRF

  `state`에 난수를 넣고 세션에 같은 값을 둔 뒤 콜백에서 대조한다.
  일치하지 않으면 거부한다. 이게 없으면 공격자가 자기 계정을 피해자 세션에 붙일 수 있다.
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

  @doc "제공자 인증 페이지 URL을 만든다."
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
  인증 코드를 프로필로 바꾼다.

  `{:ok, %{provider_id, email, name}}` 또는 `{:error, reason}`.
  """
  def fetch_profile(provider, config, code) do
    spec = Map.fetch!(@providers, provider)

    with {:ok, access_token} <- exchange_code(spec, config, code),
         {:ok, raw} <- fetch_userinfo(provider, spec, access_token) do
      normalize(provider, raw)
    end
  end

  # ── 내부 ─────────────────────────────────────────────────

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
        # 응답 본문에 토큰이 섞여 있을 수 있으니 통째로 로그에 남기지 않는다
        Logger.warning("[OAuth] 토큰 교환 실패: status=#{status} error=#{inspect(body["error"])}")
        {:error, :token_exchange_failed}

      {:error, reason} ->
        Logger.warning("[OAuth] 토큰 요청 실패: #{inspect(reason)}")
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
      # GitHub은 프로필에 이메일이 없을 수 있다 (비공개 설정). 별도 엔드포인트에서 가져온다.
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
