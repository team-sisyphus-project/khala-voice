defmodule VR.Repo.Migrations.AddTaxonomyConstraints do
  use Ecto.Migration

  @moduledoc """
  Prevents duplicate topic/label names.

  It is a **partial unique** index. If soft-deleted rows were locked in as
  well, deleting "Urgent" would mean the same name could never be created again.

  No `labels.sort_order` — labels are shown in name order only, by decision
  (`docs/03-domain-model.md`). If needed later, one migration brings it back.
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
