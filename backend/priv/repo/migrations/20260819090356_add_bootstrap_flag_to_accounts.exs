defmodule VR.Repo.Migrations.AddBootstrapFlagToAccounts do
  use Ecto.Migration

  @moduledoc """
  Marks the initial bootstrap admin.

  Right after installation nobody is an admin, so `/_admin` is unreachable.
  We therefore create one account automatically. That account is a **temporary
  key that opens the door**; the normal procedure is to promote a real user to
  admin and then delete it, closing the door again.

  Why the flag exists: so the admin UI can clearly say "this is a temporary
  account — delete it". Without the marker it just lingers as a permanent backdoor.
  """

  def change do
    alter table(:accounts) do
      add :is_bootstrap, :boolean, null: false, default: false
    end

    create index(:accounts, [:is_admin], where: "is_admin = true")
  end
end
