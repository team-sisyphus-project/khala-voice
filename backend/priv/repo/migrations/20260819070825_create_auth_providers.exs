defmodule VR.Repo.Migrations.CreateAuthProviders do
  use Ecto.Migration

  @moduledoc """
  소셜 로그인 제공자.

  `enabled`는 DB에만 존재한다. 환경변수로는 켤 수 없다.
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
