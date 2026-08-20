defmodule VR.Auth.Providers do
  @moduledoc """
  소셜 로그인 제공자 조회/관리.

  ## 활성화 판정

      enabled = true  AND  client_id 있음  AND  client_secret 있음

  셋 중 하나라도 빠지면 로그인 화면에 나타나지 않고, OAuth 라우트도 404가 된다.
  키가 없는데 켜져 있으면 어드민에 경고를 띄운다.
  """

  import Ecto.Query, warn: false

  alias VR.Auth.AuthProvider
  alias VR.Repo

  @env_map %{
    "google" =>
      {"GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET", "GOOGLE_OAUTH_REDIRECT_URI"},
    "github" =>
      {"GITHUB_OAUTH_CLIENT_ID", "GITHUB_OAUTH_CLIENT_SECRET", "GITHUB_OAUTH_REDIRECT_URI"},
    "kakao" => {"KAKAO_OAUTH_CLIENT_ID", "KAKAO_OAUTH_CLIENT_SECRET", "KAKAO_OAUTH_REDIRECT_URI"},
    "naver" => {"NAVER_OAUTH_CLIENT_ID", "NAVER_OAUTH_CLIENT_SECRET", "NAVER_OAUTH_REDIRECT_URI"},
    "apple" => {"APPLE_OAUTH_CLIENT_ID", "APPLE_OAUTH_CLIENT_SECRET", "APPLE_OAUTH_REDIRECT_URI"}
  }

  @doc "어드민용 — 모든 제공자 (미설정 포함)"
  def list_all do
    stored = Repo.all(from p in AuthProvider, order_by: [asc: :sort_order, asc: :provider])
    stored_map = Map.new(stored, &{&1.provider, &1})

    AuthProvider.providers()
    |> Enum.map(fn name ->
      stored_map[name] || %AuthProvider{provider: name, display_name: default_label(name)}
    end)
    |> Enum.map(&decorate/1)
  end

  @doc "로그인 화면용 — 실제로 쓸 수 있는 제공자만"
  def list_active do
    list_all()
    |> Enum.filter(& &1.active)
    |> Enum.sort_by(&{&1.sort_order, &1.provider})
  end

  @doc "이 제공자로 로그인할 수 있는가. OAuth 라우트가 이걸 보고 404를 낸다."
  def active?(name) when is_binary(name) do
    case get(name) do
      nil -> false
      p -> p.active
    end
  end

  def get(name), do: Enum.find(list_all(), &(&1.provider == name))

  @doc "제공자 설정 저장 (빈 비밀값은 기존 값 유지)"
  def upsert(name, attrs, opts \\ []) do
    attrs =
      attrs
      |> Map.put("provider", name)
      |> Map.put("updated_by_id", opts[:actor_id])

    existing = Repo.get_by(AuthProvider, provider: name) || %AuthProvider{}

    existing
    |> AuthProvider.admin_changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  ON/OFF 토글.

  켤 때 키가 없으면 거부한다. 켜져 있는데 키가 없는 상태를 만들지 않는다.
  """
  def set_enabled(name, enabled, opts \\ []) do
    provider = get(name)

    cond do
      enabled and not provider.credentials_present ->
        {:error, :credentials_missing}

      true ->
        upsert(name, %{"enabled" => enabled}, opts)
    end
  end

  @doc """
  이 제공자로**만** 로그인할 수 있는 계정 수.

  끄기 전에 확인한다. 0이 아니면 그 계정들이 로그인 불가가 되므로
  어드민이 확인 절차를 거치고, 해당 계정에 비밀번호 설정 안내를 보낸다.
  """
  def locked_out_account_count(name) do
    # M1에서 accounts 테이블이 생기면 실제 카운트로 교체한다.
    _ = name
    0
  end

  # ── 내부 ─────────────────────────────────────────────────

  defp decorate(%AuthProvider{} = p) do
    {id_env, secret_env, redirect_env} = Map.get(@env_map, p.provider, {nil, nil, nil})

    client_id = present(p.client_id) || env(id_env)
    client_secret = present(p.client_secret) || env(secret_env)
    redirect_uri = present(p.redirect_uri) || env(redirect_env)

    credentials_present = not is_nil(client_id) and not is_nil(client_secret)

    p
    |> Map.put(:display_name, p.display_name || default_label(p.provider))
    |> Map.merge(%{
      resolved_client_id: client_id,
      resolved_client_secret: client_secret,
      resolved_redirect_uri: redirect_uri,
      credentials_present: credentials_present,
      credentials_source: source_of(p.client_id, client_id),
      # enabled 는 DB만 본다 — 환경변수로는 켜지지 않는다
      active: p.enabled and credentials_present
    })
  end

  defp source_of(db_value, resolved) do
    cond do
      present(db_value) -> :db
      not is_nil(resolved) -> :env
      true -> :none
    end
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  defp env(nil), do: nil
  defp env(name), do: present(System.get_env(name))

  defp default_label("google"), do: "Google"
  defp default_label("github"), do: "GitHub"
  defp default_label("kakao"), do: "Kakao"
  defp default_label("naver"), do: "Naver"
  defp default_label("apple"), do: "Apple"
  defp default_label(other), do: String.capitalize(other)
end
