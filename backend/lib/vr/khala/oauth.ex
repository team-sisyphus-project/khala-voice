defmodule VR.Khala.OAuth do
  @moduledoc """
  칼라 OAuth 2.0 — **PKCE 공개 클라이언트**.

  ## 왜 client_secret 이 없나

  칼라가 `token_endpoint_auth_methods_supported: ["none"]` 을 광고한다.
  공개 클라이언트라 시크릿 자체가 없고, PKCE(S256)가 그 자리를 대신한다.

  이 리포는 오픈소스로 공개되고 **시크릿을 코드에 두지 않는다**(`CLAUDE.md`).
  시크릿이 애초에 없는 방식이라 그 규칙과 충돌하지 않는다.

  ## 왜 client_id 를 박아 두지 않나

  `registration_endpoint` 가 있어 **동적 클라이언트 등록**(RFC 7591)이 된다.
  배포 도메인마다 우리가 직접 등록해 두지 않아도 되고, 도메인이 바뀌어도
  다시 등록하면 그만이다.

  ## 엔드포인트를 코드에 적지 않는다

  `/.well-known/oauth-authorization-server` 에서 받아 쓴다. 칼라가 경로를 바꾸면
  우리가 따라 고칠 필요가 없다 — 적어 두면 그게 어긋나는 날 조용히 실패한다.
  """

  require Logger

  alias VR.Config

  @discovery_path "/.well-known/oauth-authorization-server"
  @scope "khala"

  @doc """
  칼라 MCP 주소. 설정에 없으면 `nil` — **리터럴 기본값을 두지 않는다**(`CLAUDE.md`).
  """
  def mcp_url, do: Config.fetch("khala.mcp_url")

  @doc "연동을 화면에 노출할 것인가."
  def enabled?, do: Config.fetch("khala.enabled") in [true, "true"]

  @doc """
  인가 서버 메타데이터. 매번 받는다 — 캐시하면 칼라가 바꿔도 우리가 모른다.

  MCP 주소(`https://mcp.khala.to/mcp`)의 **오리진**에서 찾는다.
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
  동적 클라이언트 등록. `client_id` 를 돌려준다.

  `redirect_uri` 는 **우리 콜백 주소**다. 칼라가 이 값으로만 되돌려 보내므로
  등록한 것과 인가 요청에 쓰는 것이 같아야 한다.
  """
  def register_client(meta, redirect_uri) do
    endpoint = meta["registration_endpoint"]

    if is_binary(endpoint) do
      body = %{
        "client_name" => "KHALA VOICE",
        "redirect_uris" => [redirect_uri],
        "grant_types" => ["authorization_code"],
        "response_types" => ["code"],
        # 공개 클라이언트 — 시크릿을 받지 않는다
        "token_endpoint_auth_method" => "none"
      }

      case Req.post(endpoint, json: body, receive_timeout: 15_000) do
        {:ok, %{status: status, body: %{"client_id" => id}}} when status in 200..201 ->
          {:ok, id}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("[Khala] 클라이언트 등록 실패 #{status}: #{inspect(body)}")
          {:error, {:register_failed, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_registration_endpoint}
    end
  end

  @doc """
  PKCE 검증자와 챌린지.

  검증자는 세션에 담아 두었다가 토큰 교환 때 그대로 보낸다. **이것이
  client_secret 을 대신한다** — 인가 코드를 가로채도 검증자가 없으면 못 바꾼다.
  """
  def pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    {verifier, challenge}
  end

  @doc "사용자를 보낼 인가 주소."
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
        # 어느 자원에 쓸 토큰인지 (RFC 8707) — MCP 는 이걸 본다
        "resource" => mcp_url()
      })

    meta["authorization_endpoint"] <> "?" <> query
  end

  @doc "인가 코드를 토큰으로 바꾼다."
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

  @doc "만료된 토큰을 갱신한다."
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
        # 토큰은 절대 로그에 남기지 않는다. 오류 코드만 남긴다.
        Logger.warning("[Khala] 토큰 요청 실패 #{status}: #{inspect(body["error"])}")
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
