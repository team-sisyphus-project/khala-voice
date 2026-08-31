defmodule VR.Repo.Migrations.DefaultThemeLight do
  use Ecto.Migration

  def up do
    alter table(:accounts) do
      modify :theme, :string, null: false, default: "light"
    end
  end

  def down do
    alter table(:accounts) do
      modify :theme, :string, null: false, default: "dark"
    end
  end
end
