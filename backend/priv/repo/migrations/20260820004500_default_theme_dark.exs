defmodule VR.Repo.Migrations.DefaultThemeDark do
  use Ecto.Migration

  @moduledoc """
  Changes the default theme to dark.

  **Only the default changes.** Accounts already on light are untouched —
  once a user's choice cannot be told apart from the default, there is no way back.
  """

  def up do
    alter table(:accounts) do
      modify :theme, :string, null: false, default: "dark"
    end
  end

  def down do
    alter table(:accounts) do
      modify :theme, :string, null: false, default: "light"
    end
  end
end
