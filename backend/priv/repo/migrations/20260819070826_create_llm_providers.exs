defmodule VR.Repo.Migrations.CreateLlmProviders do
  use Ecto.Migration

  @moduledoc """
  LLM providers for AI summaries. Tried in ascending priority order, with fallback on failure.
  """

  def change do
    create table(:llm_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :display_name, :string
      add :api_key_encrypted, :binary
      add :base_url, :string
      add :model, :string
      add :tier, :string, null: false, default: "mid"
      add :temperature, :decimal, null: false, default: 0.2
      add :max_output_tokens, :integer, null: false, default: 16384
      add :enabled, :boolean, null: false, default: false
      add :priority, :integer, null: false, default: 100
      add :updated_by_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create unique_index(:llm_providers, [:provider])
    create index(:llm_providers, [:priority])
  end
end
