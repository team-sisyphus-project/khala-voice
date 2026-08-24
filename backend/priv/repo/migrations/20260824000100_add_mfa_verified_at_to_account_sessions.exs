defmodule VR.Repo.Migrations.AddMfaVerifiedAtToAccountSessions do
  use Ecto.Migration

  def change do
    alter table(:account_sessions) do
      add :mfa_verified_at, :utc_datetime
    end
  end
end
