defmodule VR.Taxonomy.Topic do
  @moduledoc """
  Meeting classification — topics. A meeting carries **only one**.

  **Source: sisyphus** `lib/sisyphus/topics/topic.ex`. What changed:

  | sisyphus | this app | why |
  |---|---|---|
  | table `categories` | `topics` | We do not inherit the legacy name |
  | `project_id` | `owner_id` | This app has no projects. Classification belongs to the account |
  | `title` + `display_label` | `name` | The two fields were always stored with the same value |
  | `description` | none | No screen ever read it |
  | free-form HEX | palette keys (`VR.Taxonomy.Color`) | With four themes, arbitrary colors do not read against the backgrounds |
  | (none) | `sort_order` · `deleted_at` | User ordering and soft delete |

  `owner_id` is **never cast.** The context sets it on the struct —
  casting it would let a request body create classifications for someone else.
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

  @doc "Soft delete. Detaching the meetings that used it is done by the context in the same transaction."
  def delete_changeset(topic, now \\ nil) do
    change(topic, %{deleted_at: now || DateTime.utc_now(:second)})
  end

  def sort_changeset(topic, order) when is_integer(order) do
    change(topic, %{sort_order: order})
  end

  # ── Internal ─────────────────────────────────────────────

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
