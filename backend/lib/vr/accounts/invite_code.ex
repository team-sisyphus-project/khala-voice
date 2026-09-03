defmodule VR.Accounts.InviteCode do
  @moduledoc """
  Registration invite code.

  When `policy.invite_code_required` is enabled, a valid code is required to register.
  A code is consumed after a single use.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "invite_codes" do
    field :code, :string
    field :status, :string, default: "available"
    field :owner_account_id, :string
    field :used_by_account_id, :string
    field :used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :note, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Generates a code that is easy for people to read and transcribe. Confusing characters (0/O/1/I) are excluded."
  def build(attrs \\ %{}) do
    %__MODULE__{}
    |> change(%{
      id: IdGenerator.generate(:invite_code),
      code: generate_code(),
      status: "available",
      owner_account_id: attrs[:owner_account_id],
      expires_at: attrs[:expires_at],
      note: attrs[:note]
    })
    |> unique_constraint(:code)
  end

  def use_changeset(invite, account_id) do
    change(invite, %{
      status: "used",
      used_by_account_id: account_id,
      used_at: DateTime.utc_now(:second)
    })
  end

  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  defp generate_code do
    1..12
    |> Enum.map(fn _ -> Enum.random(@alphabet) end)
    |> List.to_string()
    |> String.replace(~r/(.{4})(?=.)/, "\\1-")
  end
end
