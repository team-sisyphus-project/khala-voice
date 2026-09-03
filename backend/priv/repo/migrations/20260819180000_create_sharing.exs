defmodule VR.Repo.Migrations.CreateSharing do
  use Ecto.Migration

  @moduledoc """
  Shared links · guest sessions · PIN attempt log.

  ## Tokens and PINs are never stored in plaintext

  A share token is a **credential that works immediately, with no further
  auth**. Whoever sees it — in a DB backup, a replica, logs, or a `SELECT *`
  dump — walks straight into that meeting. So, like `AccountSession`, we store
  only the sha256 hash, and the original leaves us **exactly once**, in the
  issuing response. If lost, it is reissued (`rotate`).

  PINs are 6 digits (10^6), so a leaked sha256 hash is reversed in seconds.
  We use Bcrypt for those.

  Cloak (AES-GCM) cannot be used here — the IV differs every time, making
  `WHERE token_hash = ?` lookups impossible, and `CLOAK_KEY` lives next to the
  DB credentials and leaks together with them.

  ## How this differs from sisyphus

  sisyphus put `token` · `pincode` in plaintext columns and generated PINs with
  `:rand.uniform` (not a CSPRNG), with a range bug that could never produce
  `100000`. There was no guest session table at all — guest identity was a
  browser-side JS variable.
  """

  def change do
    create table(:shared_links, primary_key: false) do
      add :id, :string, primary_key: true
      add :meeting_id, references(:meetings, type: :string, on_delete: :delete_all), null: false
      add :created_by_id, references(:accounts, type: :string, on_delete: :nilify_all)

      add :token_hash, :binary, null: false

      # First 8 chars. Only for telling links apart in lists. Not enough to get in.
      add :token_prefix, :string, null: false
      add :granted_role, :string, null: false, default: "viewer"
      # Bcrypt. nil = no PIN
      add :pin_hash, :string

      add :max_uses, :integer
      add :use_count, :integer, null: false, default: 0
      add :expires_at, :utc_datetime
      add :is_active, :boolean, null: false, default: true
      add :revoked_at, :utc_datetime

      add :require_name, :boolean, null: false, default: true
      add :require_email, :boolean, null: false, default: false

      add :failed_pin_attempts, :integer, null: false, default: 0
      add :pin_locked_until, :utc_datetime

      add :last_used_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:shared_links, [:token_hash])
    create index(:shared_links, [:meeting_id])
    create index(:shared_links, [:created_by_id])
    create index(:shared_links, [:meeting_id, :is_active], where: "deleted_at IS NULL")

    # Baked into the DB too, so a "reviewer" link cannot appear even if app validation leaks
    create constraint(:shared_links, :shared_links_granted_role_check,
             check: "granted_role IN ('viewer','contributor')"
           )

    create constraint(:shared_links, :shared_links_max_uses_check,
             check: "max_uses IS NULL OR max_uses > 0"
           )

    create constraint(:shared_links, :shared_links_use_count_check, check: "use_count >= 0")

    create table(:guest_sessions, primary_key: false) do
      add :id, :string, primary_key: true

      add :shared_link_id, references(:shared_links, type: :string, on_delete: :delete_all),
        null: false

      # The **single-meeting access** constraint is baked into the row.
      # The data, not the controller, must carry the scope.
      add :meeting_id, references(:meetings, type: :string, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, type: :string, on_delete: :delete_all)

      add :token_hash, :binary, null: false

      # Copied from the link and frozen. If the link's role changes later, this session keeps its own.
      add :granted_role, :string, null: false
      add :display_name, :string
      add :email, :string
      add :user_agent, :string
      add :ip_address, :string

      add :last_activity_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:guest_sessions, [:token_hash])
    create index(:guest_sessions, [:shared_link_id])
    create index(:guest_sessions, [:meeting_id])
    create index(:guest_sessions, [:expires_at])

    create constraint(:guest_sessions, :guest_sessions_granted_role_check,
             check: "granted_role IN ('viewer','contributor')"
           )

    # Attempt log for PIN brute-force defense.
    # We do not reuse `login_attempts` — it would blur the meaning of that table's email column.
    create table(:share_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :binary
      add :ip_address, :string
      add :success, :boolean, null: false, default: false
      add :attempted_at, :utc_datetime, null: false
    end

    create index(:share_attempts, [:token_hash, :attempted_at])
    create index(:share_attempts, [:ip_address, :attempted_at])
  end
end
