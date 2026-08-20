defmodule VR.Friends.Friendship do
  @moduledoc """
  친구 관계. **양방향을 한 행으로** 저장한다.

  두 계정 ID를 정렬해서 항상 `account_a_id < account_b_id`가 되게 넣는다.
  이러면 (A,B)와 (B,A)가 같은 행이 되어 중복이 구조적으로 불가능하고,
  유니크 인덱스 하나로 끝난다.

  조회는 `where a = me or b = me`.
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

  @doc "두 계정으로 관계를 만든다. 순서는 알아서 정렬한다."
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

  @doc "두 ID를 항상 같은 순서로 정렬한다."
  def order_pair(id_1, id_2) when id_1 <= id_2, do: {id_1, id_2}
  def order_pair(id_1, id_2), do: {id_2, id_1}

  defp validate_distinct(changeset) do
    a = get_field(changeset, :account_a_id)
    b = get_field(changeset, :account_b_id)

    if a == b do
      add_error(changeset, :account_b_id, "자기 자신과는 친구가 될 수 없습니다")
    else
      changeset
    end
  end
end
