defmodule VR.Sharing.ShareAttempt do
  @moduledoc """
  A PIN entry attempt on a shared link.

  **Source: this repo's `VR.Accounts.LoginAttempt`** — same shape.
  `login_attempts` is not reused — it would blur the meaning of that table's
  `email` column.

  Used to block per-IP brute forcing. With only per-link lockouts, an attacker
  alternating across multiple links cannot be stopped.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "share_attempts" do
    field :token_hash, :binary, redact: true
    field :ip_address, :string
    field :success, :boolean, default: false
    field :attempted_at, :utc_datetime
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:token_hash, :ip_address, :success])
    |> put_change(:attempted_at, DateTime.utc_now(:second))
  end
end
