defmodule VR.Friends.Friendship do
  @moduledoc """
  Friendship. **Both directions stored as one row.**

  The two account IDs are sorted so that `account_a_id < account_b_id` always
  holds. That makes (A,B) and (B,A) the same row, so duplicates are structurally
  impossible and a single unique index suffices.

  Lookup is `where a = me or b = me`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "friendships" do
    field :account_a_id, :string
    field :account_b_id, :string
    field :status, :string, default: "active"
    field :blocked_by_id, :string
    field :became_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Builds a friendship from two accounts. Ordering is handled automatically."
  def build(account_id_1, account_id_2) do
    {a, b} = order_pair(account_id_1, account_id_2)

    %__MODULE__{}
    |> change(%{
      id: IdGenerator.generate(:friendship),
      account_a_id: a,
      account_b_id: b,
      status: "active",
      became_at: DateTime.utc_now(:second)
    })
    |> validate_distinct()
    |> unique_constraint([:account_a_id, :account_b_id])
  end

  def block_changeset(friendship, blocked_by_id) do
    change(friendship, %{status: "blocked", blocked_by_id: blocked_by_id})
  end

  def unblock_changeset(friendship) do
    change(friendship, %{status: "active", blocked_by_id: nil})
  end

  @doc "Sorts two IDs into a consistent order."
  def order_pair(id_1, id_2) when id_1 <= id_2, do: {id_1, id_2}
  def order_pair(id_1, id_2), do: {id_2, id_1}

  defp validate_distinct(changeset) do
    a = get_field(changeset, :account_a_id)
    b = get_field(changeset, :account_b_id)

    if a == b do
      add_error(changeset, :account_b_id, "cannot be friends with yourself")
    else
      changeset
    end
  end
end
