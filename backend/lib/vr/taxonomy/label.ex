defmodule VR.Taxonomy.Label do
  @moduledoc """
  회의 분류 — 라벨. 회의 하나에 **여러 개** 붙는다 (`meetings.label_ids`).

  **출처: sisyphus** `lib/sisyphus/labels/label.ex`. 바꾼 것은
  `VR.Taxonomy.Topic` 과 같다 (`project_id`→`owner_id`, 자유 HEX→팔레트 키 등).
  이름 길이 상한 20자는 원본 그대로 가져왔다.

  ## 토픽과 달리 `sort_order` 가 없다

  라벨은 이름순으로만 보여준다. 라벨은 개수가 늘기 쉬워서 수동 정렬이
  금세 관리 부담이 된다. 필요해지면 마이그레이션 하나로 되돌릴 수 있다.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator
  alias VR.Taxonomy.Color

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "labels" do
    field :owner_id, :string
    field :name, :string
    field :color, :string
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @name_max 20

  def name_max, do: @name_max

  def create_changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :color])
    |> put_id()
    |> put_default_color()
    |> validate()
  end

  def update_changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :color])
    |> validate()
  end

  @doc "소프트 삭제. 회의의 `label_ids` 에서 빼는 것은 컨텍스트가 같은 트랜잭션에서 한다."
  def delete_changeset(label, now \\ nil) do
    change(label, %{deleted_at: now || DateTime.utc_now(:second)})
  end

  # ── 내부 ─────────────────────────────────────────────────

  defp validate(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:id, :owner_id, :name])
    |> validate_length(:name, min: 1, max: @name_max)
    |> validate_inclusion(:color, Color.keys())
    |> unique_constraint([:owner_id, :name], name: :labels_owner_id_name_index)
  end

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      value when value in [nil, ""] -> put_change(changeset, :id, IdGenerator.generate(:label))
      _ -> changeset
    end
  end

  defp put_default_color(changeset) do
    case get_field(changeset, :color) do
      value when value in [nil, ""] -> put_change(changeset, :color, Color.default())
      _ -> changeset
    end
  end
end
