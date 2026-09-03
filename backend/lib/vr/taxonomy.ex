defmodule VR.Taxonomy do
  @moduledoc """
  Topics and labels — meeting classification.

  **Source: sisyphus** — the CRUD skeleton of `lib/sisyphus/topics.ex` and
  `lib/sisyphus/labels.ex`. Soft delete, detach-on-delete, user ordering, and
  ownership validation were **written new in this app**.

  ## Classification belongs to the account

  In sisyphus, projects owned it. This app has no projects, so accounts own it.
  The only things that can be attached to a meeting are **the meeting owner's
  classifications** — if a Contributor attached their own label to someone
  else's meeting, the owner's archive search would never surface it under the
  owner's classifications.

  ## Deleting detaches from the meetings that used it

  Leaving only the reference means that meeting **matches no filter at all.**
  A deleted topic is absent from the filter list, so it cannot be selected, and
  the leftover reference keeps the meeting out of "unclassified" too. In an app
  whose main use is archive search, that is silent data loss.
  So the soft delete and the detach happen in **one transaction**.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias VR.Accounts.Account
  alias VR.Meetings.Meeting
  alias VR.Repo
  alias VR.Taxonomy.{Label, Topic}

  # ── Lookup ───────────────────────────────────────────────

  @doc "My topics. Sort order, then name."
  def list_topics(owner, opts \\ [])
  def list_topics(%Account{id: id}, opts), do: list_topics(id, opts)

  def list_topics(owner_id, _opts) when is_binary(owner_id) do
    Repo.all(
      from t in Topic,
        where: t.owner_id == ^owner_id and is_nil(t.deleted_at),
        order_by: [asc: t.sort_order, asc: t.name]
    )
  end

  @doc "My labels. By name."
  def list_labels(owner, opts \\ [])
  def list_labels(%Account{id: id}, opts), do: list_labels(id, opts)

  def list_labels(owner_id, _opts) when is_binary(owner_id) do
    Repo.all(
      from l in Label,
        where: l.owner_id == ^owner_id and is_nil(l.deleted_at),
        order_by: [asc: l.name]
    )
  end

  @doc """
  Returns each topic with its meeting count. The management screen has to show
  "how many meetings get detached if this is deleted".

  Deleted meetings are not counted.
  """
  def list_topics_with_counts(owner) do
    owner_id = account_id(owner)
    counts = topic_counts(owner_id)

    owner_id
    |> list_topics()
    |> Enum.map(&%{topic: &1, meeting_count: Map.get(counts, &1.id, 0)})
  end

  def list_labels_with_counts(owner) do
    owner_id = account_id(owner)
    counts = label_counts(owner_id)

    owner_id
    |> list_labels()
    |> Enum.map(&%{label: &1, meeting_count: Map.get(counts, &1.id, 0)})
  end

  @doc "One of my topics. **nil if it belongs to someone else** — must be indistinguishable from nonexistent."
  def get_topic(owner_id, id) when is_binary(owner_id) and is_binary(id) do
    Repo.one(
      from t in Topic,
        where: t.owner_id == ^owner_id and t.id == ^id and is_nil(t.deleted_at)
    )
  end

  def get_topic(_owner_id, _id), do: nil

  def get_label(owner_id, id) when is_binary(owner_id) and is_binary(id) do
    Repo.one(
      from l in Label,
        where: l.owner_id == ^owner_id and l.id == ^id and is_nil(l.deleted_at)
    )
  end

  def get_label(_owner_id, _id), do: nil

  @doc """
  Batch resolution used when rendering a meeting list.

  **Deleted classifications are returned too.** Rendering a reference still on a
  meeting without its name puts an unidentifiable chip on screen.
  """
  def resolve_for(meetings) when is_list(meetings) do
    topic_ids = meetings |> Enum.map(& &1.topic_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    label_ids = meetings |> Enum.flat_map(&(&1.label_ids || [])) |> Enum.uniq()

    %{
      topics: fetch_by_ids(Topic, topic_ids),
      labels: fetch_by_ids(Label, label_ids)
    }
  end

  # ── Create & update ──────────────────────────────────────

  @doc "Creates a topic. Its sort order is appended at the end."
  def create_topic(owner, attrs \\ %{}) do
    owner_id = account_id(owner)

    %Topic{owner_id: owner_id, sort_order: next_sort_order(owner_id)}
    |> Topic.create_changeset(attrs)
    |> Repo.insert()
  end

  def create_label(owner, attrs \\ %{}) do
    %Label{owner_id: account_id(owner)}
    |> Label.create_changeset(attrs)
    |> Repo.insert()
  end

  def update_topic(%Topic{} = topic, attrs) do
    topic |> Topic.update_changeset(attrs) |> Repo.update()
  end

  def update_label(%Label{} = label, attrs) do
    label |> Label.update_changeset(attrs) |> Repo.update()
  end

  # ── Delete ───────────────────────────────────────────────

  @doc """
  Deletes a topic and detaches it from the meetings that used it. One transaction.

  Returns how many were detached — the basis for the user to decide whether to
  undo.
  """
  def delete_topic(%Topic{} = topic) do
    Multi.new()
    |> Multi.update(:topic, Topic.delete_changeset(topic))
    |> Multi.update_all(
      :detach,
      from(m in Meeting, where: m.topic_id == ^topic.id),
      set: [topic_id: nil]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{topic: deleted, detach: {count, _}}} ->
        {:ok, %{topic: deleted, detached_meetings: count}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc "Deletes a label and removes **only that id** from meetings' `label_ids`."
  def delete_label(%Label{} = label) do
    Multi.new()
    |> Multi.update(:label, Label.delete_changeset(label))
    |> Multi.update_all(
      :detach,
      from(m in Meeting,
        where: fragment("? = ANY(?)", ^label.id, m.label_ids),
        update: [set: [label_ids: fragment("array_remove(?, ?)", m.label_ids, ^label.id)]]
      ),
      []
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{label: deleted, detach: {count, _}}} ->
        {:ok, %{label: deleted, detached_meetings: count}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # ── Ordering ─────────────────────────────────────────────

  @doc """
  Reorders topics. Takes **the entire list at once**.

  Accepting a partial reorder would force the server to guess the order of the
  omitted ones, and two windows moving items concurrently would leave the order
  inconsistent. If even one is not mine, or the count differs, **nothing changes.**
  """
  def reorder_topics(owner, ids) when is_list(ids) do
    owner_id = account_id(owner)
    mine = list_topics(owner_id)
    mine_ids = MapSet.new(mine, & &1.id)

    cond do
      length(ids) != length(mine) ->
        {:error, :unknown_topic}

      not MapSet.equal?(MapSet.new(ids), mine_ids) ->
        {:error, :unknown_topic}

      true ->
        ids
        |> Enum.with_index()
        |> Enum.reduce(Multi.new(), fn {id, index}, multi ->
          Multi.update_all(multi, {:sort, id}, from(t in Topic, where: t.id == ^id),
            set: [sort_order: index]
          )
        end)
        |> Repo.transaction()
        |> case do
          {:ok, _} -> {:ok, list_topics(owner_id)}
          {:error, _step, reason, _changes} -> {:error, reason}
        end
    end
  end

  # ── Attaching to meetings ────────────────────────────────

  @doc """
  Are these values attachable to the meeting? Only **the meeting owner's
  classifications** are allowed.

  If a Contributor attached their own label to someone else's meeting, that
  meeting would not surface under the owner's classifications in the owner's
  archive search. It would become a classification only the person who attached
  it knows about.
  """
  def validate_assignment(owner_id, topic_id, label_ids)

  def validate_assignment(owner_id, topic_id, label_ids) when is_binary(owner_id) do
    with :ok <- validate_topic(owner_id, topic_id) do
      validate_labels(owner_id, label_ids)
    end
  end

  def validate_assignment(_owner_id, _topic_id, _label_ids), do: {:error, :invalid_topic}

  defp validate_topic(_owner_id, nil), do: :ok
  defp validate_topic(_owner_id, ""), do: :ok

  defp validate_topic(owner_id, topic_id) do
    if get_topic(owner_id, topic_id), do: :ok, else: {:error, :invalid_topic}
  end

  defp validate_labels(_owner_id, nil), do: :ok
  defp validate_labels(_owner_id, []), do: :ok

  defp validate_labels(owner_id, ids) when is_list(ids) do
    found =
      Repo.all(
        from l in Label,
          where: l.owner_id == ^owner_id and l.id in ^ids and is_nil(l.deleted_at),
          select: l.id
      )

    if MapSet.equal?(MapSet.new(found), MapSet.new(ids)),
      do: :ok,
      else: {:error, :invalid_label}
  end

  defp validate_labels(_owner_id, _ids), do: {:error, :invalid_label}

  # ── Internal ─────────────────────────────────────────────

  defp account_id(%Account{id: id}), do: id
  defp account_id(id) when is_binary(id), do: id

  defp next_sort_order(owner_id) do
    max =
      Repo.one(
        from t in Topic,
          where: t.owner_id == ^owner_id,
          select: max(t.sort_order)
      )

    (max || -1) + 1
  end

  defp topic_counts(owner_id) do
    Repo.all(
      from m in Meeting,
        where: m.owner_id == ^owner_id and not is_nil(m.topic_id) and is_nil(m.deleted_at),
        group_by: m.topic_id,
        select: {m.topic_id, count(m.id)}
    )
    |> Map.new()
  end

  defp label_counts(owner_id) do
    Repo.all(
      from m in Meeting,
        where: m.owner_id == ^owner_id and is_nil(m.deleted_at),
        select: m.label_ids
    )
    |> List.flatten()
    |> Enum.frequencies()
  end

  defp fetch_by_ids(_schema, []), do: %{}

  defp fetch_by_ids(schema, ids) do
    Repo.all(from x in schema, where: x.id in ^ids) |> Map.new(&{&1.id, &1})
  end
end
