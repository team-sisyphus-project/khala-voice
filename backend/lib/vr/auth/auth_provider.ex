defmodule VR.Auth.AuthProvider do
  @moduledoc """
  Social login provider configuration.

  Social login is **not required.** A provider appears on the login screen only when
  its keys exist in the DB (or environment variables) and `enabled` is turned on in the admin.

  The `enabled` switch reads **only the DB.** Environment variables alone cannot turn it on.
  This prevents login methods from changing without notice due to variable differences
  across deployment environments.
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
  Keeps the existing value when a secret field is submitted empty.
  Saving from the admin form without touching the masked field is the normal behavior.
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
