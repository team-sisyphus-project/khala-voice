defmodule VR.Accounts.InviteCode do
  @moduledoc """
  가입 초대 코드.

  `policy.invite_code_required`를 켜면 가입 시 유효한 코드가 필요하다.
  코드는 한 번 쓰면 소진된다.
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

  @doc "사람이 읽고 옮겨적기 쉬운 코드를 만든다. 헷갈리는 글자(0/O/1/I)를 뺀다."
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
