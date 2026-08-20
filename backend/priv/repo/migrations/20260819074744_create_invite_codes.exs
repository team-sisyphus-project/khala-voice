defmodule VR.Repo.Migrations.CreateInviteCodes do
  use Ecto.Migration

  def change do
    create table(:invite_codes, primary_key: false) do
      add :id, :string, primary_key: true
      add :code, :citext, null: false
      add :status, :string, null: false, default: "available"
      add :owner_account_id, references(:accounts, type: :string, on_delete: :nilify_all)
      add :used_by_account_id, references(:accounts, type: :string, on_delete: :nilify_all)
      add :used_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invite_codes, [:code])
    create index(:invite_codes, [:status])
    create index(:invite_codes, [:owner_account_id])
  end
end
