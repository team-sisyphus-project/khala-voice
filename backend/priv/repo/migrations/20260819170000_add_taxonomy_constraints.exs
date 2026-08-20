defmodule VR.Repo.Migrations.AddTaxonomyConstraints do
  use Ecto.Migration

  @moduledoc """
  토픽·라벨 이름 중복 방지.

  **부분 유니크**다. 소프트 삭제된 행까지 포함해 잠그면
  "긴급"을 지운 뒤 같은 이름으로 다시 만들 수 없다.

  `labels.sort_order` 는 두지 않는다 — 라벨은 이름순으로만 보여주기로 했다
  (`docs/03-domain-model.md`). 나중에 필요하면 마이그레이션 하나로 되돌릴 수 있다.
  """

  def change do
    create unique_index(:topics, [:owner_id, :name],
             where: "deleted_at IS NULL",
             name: :topics_owner_id_name_index
           )

    create unique_index(:labels, [:owner_id, :name],
             where: "deleted_at IS NULL",
             name: :labels_owner_id_name_index
           )

    create index(:topics, [:owner_id, :sort_order], where: "deleted_at IS NULL")
  end
end
