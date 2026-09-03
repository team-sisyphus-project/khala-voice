defmodule VR.Repo.Migrations.CreateFriends do
  use Ecto.Migration

  @moduledoc """
  Friendships and invitations.

  A relationship is one row holding an ordered pair — a single unique index
  blocks (A,B)/(B,A) duplicates.
  """

  def change do
    create table(:friendships, primary_key: false) do
      add :id, :string, primary_key: true
      add :account_a_id, references(:accounts, type: :string, on_delete: :delete_all), null: false
      add :account_b_id, references(:accounts, type: :string, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "active"
      add :blocked_by_id, :string
      add :became_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:friendships, [:account_a_id, :account_b_id])
    create index(:friendships, [:account_b_id])

    # Enforce the ordering rule at the DB level. Even if code slips, a wrong order cannot get in.
    create constraint(:friendships, :friendship_pair_ordered,
             check: "account_a_id < account_b_id"
           )

    create table(:friend_invitations, primary_key: false) do
      add :id, :string, primary_key: true

      add :invited_by_id, references(:accounts, type: :string, on_delete: :delete_all),
        null: false

      add :email, :citext
      add :token_hash, :binary, null: false
      add :status, :string, null: false, default: "pending"
      add :message, :string
      add :expires_at, :utc_datetime, null: false
      add :accepted_by_id, references(:accounts, type: :string, on_delete: :nilify_all)
      add :responded_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:friend_invitations, [:token_hash])
    create index(:friend_invitations, [:invited_by_id, :status])
    create index(:friend_invitations, [:email, :status], where: "email IS NOT NULL")
  end
end
