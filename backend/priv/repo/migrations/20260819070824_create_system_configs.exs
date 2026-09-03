defmodule VR.Repo.Migrations.CreateSystemConfigs do
  use Ecto.Migration

  @moduledoc """
  System-wide settings (key-value).

  Values are always Cloak-encrypted into `value_encrypted`.
  There is no plaintext column — we simply never create a path
  for a secret to accidentally land in plaintext.
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
