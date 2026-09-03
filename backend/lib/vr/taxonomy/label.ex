defmodule VR.Taxonomy.Label do
  @moduledoc """
  Meeting classification — labels. A meeting can carry **several** (`meetings.label_ids`).

  **Source: sisyphus** `lib/sisyphus/labels/label.ex`. The changes are the same
  as `VR.Taxonomy.Topic` (`project_id`→`owner_id`, free-form HEX→palette keys, etc.).
  The 20-character name limit was kept from the original.

  ## Unlike topics, there is no `sort_order`

  Labels are shown only in name order. Labels multiply easily, so manual
  ordering quickly becomes a maintenance burden. If needed, one migration can
  bring it back.
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

  @doc "Soft delete. Removing it from meetings' `label_ids` is done by the context in the same transaction."
  def delete_changeset(label, now \\ nil) do
    change(label, %{deleted_at: now || DateTime.utc_now(:second)})
  end

  # ── Internal ─────────────────────────────────────────────

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
