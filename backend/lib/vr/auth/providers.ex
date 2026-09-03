defmodule VR.Auth.Providers do
  @moduledoc """
  Social login provider lookup/management.

  ## Activation criteria

      enabled = true  AND  client_id present  AND  client_secret present

  If any of the three is missing, the provider does not appear on the login screen
  and its OAuth routes return 404. If it is enabled but the keys are missing,
  a warning is shown in the admin.
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

  @doc "For the admin — all providers (including unconfigured ones)"
  def list_all do
    stored = Repo.all(from p in AuthProvider, order_by: [asc: :sort_order, asc: :provider])
    stored_map = Map.new(stored, &{&1.provider, &1})

    AuthProvider.providers()
    |> Enum.map(fn name ->
      stored_map[name] || %AuthProvider{provider: name, display_name: default_label(name)}
    end)
    |> Enum.map(&decorate/1)
  end

  @doc "For the login screen — only providers that can actually be used"
  def list_active do
    list_all()
    |> Enum.filter(& &1.active)
    |> Enum.sort_by(&{&1.sort_order, &1.provider})
  end

  @doc "Can users log in with this provider? OAuth routes consult this to return 404."
  def active?(name) when is_binary(name) do
    case get(name) do
      nil -> false
      p -> p.active
    end
  end

  def get(name), do: Enum.find(list_all(), &(&1.provider == name))

  @doc "Saves provider configuration (an empty secret keeps the existing value)"
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
  ON/OFF toggle.

  Turning on without keys is refused. Never create a state that is enabled but keyless.
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
  Number of accounts that can log in **only** with this provider.

  Checked before turning off. If non-zero, those accounts would become unable to log in,
  so the admin goes through a confirmation step and a password-setup notice is sent to them.
  """
  def locked_out_account_count(name) do
    # Replace with the real count once the accounts table lands in M1.
    _ = name
    0
  end

  # ── Internal ─────────────────────────────────────────────

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
      # enabled reads only the DB — environment variables cannot turn it on
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
