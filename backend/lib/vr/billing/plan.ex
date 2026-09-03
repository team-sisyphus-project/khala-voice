defmodule VR.Billing.Plan do
  @moduledoc """
  The identity and **mutable** metadata of a sellable subscription product.

  **Source: devkanban** `lib/manualsquad/billing/plan.ex`
  — removed the workspace and enterprise-contract fields.

  **Commercial terms** like price and included credits **do not live here.**
  That is `PlanRevision`. This split makes grandfathering automatic — editing
  metadata never disturbs existing contracts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.Billing.PlanRevision
  alias VR.IdGenerator

  @statuses ~w(draft published deprecated retired)

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "plans" do
    field :key, :string
    field :status, :string, default: "draft"
    field :display_name, :string
    field :description, :string
    field :name_i18n, :map, default: %{}
    field :description_i18n, :map, default: %{}
    field :icon, :string
    field :sort_order, :integer, default: 0
    field :publicly_listed, :boolean, default: false

    has_many :revisions, PlanRevision, foreign_key: :plan_id

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :key,
      :status,
      :display_name,
      :description,
      :name_i18n,
      :description_i18n,
      :icon,
      :sort_order,
      :publicly_listed
    ])
    |> put_id()
    |> validate_required([:id, :key, :display_name])
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:key, ~r/^[a-z0-9_]+$/, message: "must contain only lowercase letters, digits, and underscores")
    |> unique_constraint(:key)
  end

  @doc """
  Changes metadata only. **Takes effect for everyone immediately.**

  Commercial terms (price, credits, limits) cannot be changed here — a new
  revision must be published.
  """
  def meta_changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :display_name,
      :description,
      :name_i18n,
      :description_i18n,
      :icon,
      :sort_order,
      :publicly_listed,
      :status
    ])
    |> validate_required([:display_name])
    |> validate_inclusion(:status, @statuses)
  end

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:plan))
      "" -> put_change(changeset, :id, IdGenerator.generate(:plan))
      _ -> changeset
    end
  end
end
