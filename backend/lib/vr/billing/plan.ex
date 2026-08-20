defmodule VR.Billing.Plan do
  @moduledoc """
  판매 가능한 구독 상품의 정체성과 **가변** 메타.

  **출처: devkanban** `lib/manualsquad/billing/plan.ex`
  — 워크스페이스 · 엔터프라이즈 계약 필드를 제거했다.

  가격·포함 크레딧 같은 **상업 조건은 여기 없다.** 그건 `PlanRevision` 이다.
  이 구분이 그랜드파더링을 자동으로 만든다 — 메타를 고쳐도 계약이 흔들리지 않는다.
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
    |> validate_format(:key, ~r/^[a-z0-9_]+$/, message: "소문자·숫자·밑줄만 씁니다")
    |> unique_constraint(:key)
  end

  @doc """
  메타만 바꾼다. **즉시 전원에게 반영된다.**

  상업 조건(가격·크레딧·한도)은 여기서 못 바꾼다 — 새 리비전을 발행해야 한다.
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
