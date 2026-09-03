defmodule VR.System.SystemConfig do
  @moduledoc """
  System-wide configuration (key-value).

  Values are **always stored encrypted**. Encrypting non-secret values too means
  never having to decide "is this a secret?" each time, which reduces mistakes.
  Whether to mask a value on screen is decided by the `secret` flag in
  `VR.Config.Registry`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "system_configs" do
    field :key, :string
    field :value, VR.Encrypted.Binary, source: :value_encrypted
    field :updated_by_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:key, :value, :updated_by_id])
    |> validate_required([:key])
    |> validate_known_key()
    |> unique_constraint(:key)
  end

  defp validate_known_key(changeset) do
    validate_change(changeset, :key, fn :key, key ->
      if VR.Config.Registry.entry(key), do: [], else: [key: "is not a known configuration key"]
    end)
  end
end
