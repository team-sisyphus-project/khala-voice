defmodule VR.Accounts.LoginAttempt do
  @moduledoc """
  Login attempt records. Used to slow down brute-force attacks.

  Email and IP are counted **separately.** Watching only one is easy to bypass.

  - Repeated attempts on one email → an attack targeting that account
  - Attempts on many emails from one IP → credential stuffing
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "login_attempts" do
    field :email, :string
    field :ip_address, :string
    field :success, :boolean, default: false
    field :attempted_at, :utc_datetime
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:email, :ip_address, :success])
    |> put_change(:attempted_at, DateTime.utc_now(:second))
  end
end
