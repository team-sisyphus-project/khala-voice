defmodule VR.Repo.Migrations.AddThemeAndAdminMfa do
  use Ecto.Migration

  @moduledoc """
  Per-user theme preference and system-admin two-factor auth.

  ## Theme

  **Each user picks this for themselves.** It is not set by the system admin.
  The UI is needed before login too, so it is cached in localStorage;
  this column is the source of truth.

  ## MFA

  Applies to **system admins only**. Never exposed to regular users.
  A system admin operates the entire system, so a compromised account has a
  very different blast radius.
  """

  def change do
    alter table(:accounts) do
      add :theme, :string, null: false, default: "light"

      # TOTP secret. Stored Cloak-encrypted —
      # if it leaks in plaintext, two-factor auth is meaningless.
      add :mfa_secret_encrypted, :binary
      add :mfa_enabled, :boolean, null: false, default: false
      add :mfa_enabled_at, :utc_datetime
      # One-time codes for when the authenticator is lost. Stored as hashes only.
      add :mfa_backup_hashes, {:array, :string}, null: false, default: []
    end
  end
end
