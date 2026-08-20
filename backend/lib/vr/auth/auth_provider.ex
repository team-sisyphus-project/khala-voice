defmodule VR.Auth.AuthProvider do
  @moduledoc """
  소셜 로그인 제공자 설정.

  소셜 로그인은 **필수가 아니다.** 키가 DB(또는 환경변수)에 있고
  어드민에서 `enabled`를 켰을 때만 로그인 화면에 나타난다.

  `enabled` 스위치는 **DB만** 본다. 환경변수만으로는 켜지지 않는다.
  배포 환경의 변수 차이 때문에 로그인 수단이 예고 없이 바뀌는 것을 막기 위함이다.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(google github kakao naver apple)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "auth_providers" do
    field :provider, :string
    field :display_name, :string
    field :client_id, :string
    field :client_secret, VR.Encrypted.Binary, source: :client_secret_encrypted
    field :redirect_uri, :string
    field :scopes, {:array, :string}, default: []
    field :enabled, :boolean, default: false
    field :sort_order, :integer, default: 0
    field :updated_by_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  def providers, do: @providers

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :provider,
      :display_name,
      :client_id,
      :client_secret,
      :redirect_uri,
      :scopes,
      :enabled,
      :sort_order,
      :updated_by_id
    ])
    |> validate_required([:provider])
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint(:provider)
  end

  @doc """
  비밀값 필드를 빈 값으로 보낸 경우 기존 값을 유지한다.
  어드민 폼에서 마스킹된 필드를 건드리지 않고 저장하는 것이 정상 동작이다.
  """
  def admin_changeset(provider, attrs) do
    attrs = drop_blank(attrs, ["client_secret", :client_secret])
    changeset(provider, attrs)
  end

  defp drop_blank(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      case Map.get(acc, key) do
        v when v in [nil, ""] -> Map.delete(acc, key)
        _ -> acc
      end
    end)
  end
end
