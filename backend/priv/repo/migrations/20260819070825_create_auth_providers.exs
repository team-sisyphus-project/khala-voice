defmodule VR.Repo.Migrations.CreateAuthProviders do
  use Ecto.Migration

  @moduledoc """
  Social login providers.

  `enabled` exists only in the DB. It cannot be turned on via environment variables.
  """

  def change do
    create table(:auth_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :display_name, :string
      add :client_id, :string
      add :client_secret_encrypted, :binary
      add :redirect_uri, :string
      add :scopes, {:array, :string}, default: []
      add :enabled, :boolean, null: false, default: false
      add :sort_order, :integer, null: false, default: 0
      add :updated_by_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create unique_index(:auth_providers, [:provider])
  end
end
