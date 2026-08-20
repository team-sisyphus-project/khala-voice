defmodule VR.Repo.Migrations.CreateSystemConfigs do
  use Ecto.Migration

  @moduledoc """
  시스템 전역 설정 (key-value).

  값은 항상 Cloak으로 암호화되어 `value_encrypted`에 들어간다.
  평문 컬럼은 두지 않는다 — 실수로 비밀값이 평문에 들어가는 경로를 아예 만들지 않는다.
  """

  def change do
    create table(:system_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :value_encrypted, :binary
      add :updated_by_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create unique_index(:system_configs, [:key])
  end
end
