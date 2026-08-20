defmodule VR.Taxonomy.Topic do
  @moduledoc """
  회의 분류 — 토픽. 회의 하나에 **하나만** 붙는다.

  **출처: sisyphus** `lib/sisyphus/topics/topic.ex`. 바꾼 것:

  | sisyphus | 이 앱 | 왜 |
  |---|---|---|
  | 테이블 `categories` | `topics` | 레거시 이름을 물려받지 않는다 |
  | `project_id` | `owner_id` | 이 앱에는 프로젝트가 없다. 분류는 계정의 것이다 |
  | `title` + `display_label` | `name` | 두 필드가 늘 같은 값으로 저장돼 있었다 |
  | `description` | 없음 | 아무 화면도 읽지 않았다 |
  | 자유 HEX | 팔레트 키 (`VR.Taxonomy.Color`) | 테마가 넷이라 임의 색이 배경에서 안 읽힌다 |
  | (없음) | `sort_order` · `deleted_at` | 사용자 정렬과 소프트 삭제 |

  `owner_id` 는 **절대 cast 하지 않는다.** 컨텍스트가 구조체에 박는다 —
  cast 하면 요청 본문으로 남의 분류를 만들 수 있다.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias VR.IdGenerator
  alias VR.Taxonomy.Color

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "topics" do
    field :owner_id, :string
    field :name, :string
    field :color, :string
    field :sort_order, :integer, default: 0
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @name_max 30

  def name_max, do: @name_max

  def create_changeset(topic, attrs) do
    topic
    |> cast(attrs, [:name, :color])
    |> put_id()
    |> put_default_color()
    |> validate()
  end

  def update_changeset(topic, attrs) do
    topic
    |> cast(attrs, [:name, :color])
    |> validate()
  end

  @doc "소프트 삭제. 쓰던 회의를 떼어내는 것은 컨텍스트가 같은 트랜잭션에서 한다."
  def delete_changeset(topic, now \\ nil) do
    change(topic, %{deleted_at: now || DateTime.utc_now(:second)})
  end

  def sort_changeset(topic, order) when is_integer(order) do
    change(topic, %{sort_order: order})
  end

  # ── 내부 ─────────────────────────────────────────────────

  defp validate(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:id, :owner_id, :name])
    |> validate_length(:name, min: 1, max: @name_max)
    |> validate_inclusion(:color, Color.keys())
    |> unique_constraint([:owner_id, :name], name: :topics_owner_id_name_index)
  end

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      value when value in [nil, ""] -> put_change(changeset, :id, IdGenerator.generate(:topic))
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
