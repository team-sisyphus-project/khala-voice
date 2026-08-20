defmodule VR.System.SystemConfig do
  @moduledoc """
  시스템 전역 설정 (key-value).

  값은 **항상 암호화되어** 저장된다. 비밀이 아닌 값도 암호화하는 편이
  "이건 비밀인가?"를 매번 판단하지 않아도 되어 실수가 줄어든다.
  화면에서 마스킹할지 여부는 `VR.Config.Registry`의 `secret` 플래그가 정한다.
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
      if VR.Config.Registry.entry(key), do: [], else: [key: "알 수 없는 설정 키입니다"]
    end)
  end
end
