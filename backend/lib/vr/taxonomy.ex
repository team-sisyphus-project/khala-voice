defmodule VR.Taxonomy do
  @moduledoc """
  토픽 · 라벨 — 회의 분류.

  **출처: sisyphus** `lib/sisyphus/topics.ex` · `lib/sisyphus/labels.ex` 의 CRUD 골격.
  소프트 삭제 · 삭제 시 detach · 사용자 정렬 · 소유권 검증은 **이 앱에서 새로 썼다**.

  ## 분류는 계정의 것이다

  sisyphus 는 프로젝트가 소유했다. 이 앱에는 프로젝트가 없으므로 계정이 소유한다.
  회의에 붙일 수 있는 것은 **그 회의 owner 의 분류뿐**이다 — Contributor 가
  자기 라벨을 남의 회의에 붙이면 owner 의 아카이브 검색이 자기 분류로 안 걸린다.

  ## 삭제하면 쓰던 회의에서 떼어낸다

  참조만 남기면 그 회의는 **어떤 필터로도 걸리지 않는다.** 삭제된 토픽은 필터
  목록에 없으니 고를 수 없고, 남은 참조 때문에 "분류 없음" 으로도 안 잡힌다.
  아카이브 검색이 주 용도인 앱에서 이건 조용한 데이터 유실이다.
  그래서 소프트 삭제와 detach 를 **한 트랜잭션**에서 한다.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias VR.Accounts.Account
  alias VR.Meetings.Meeting
  alias VR.Repo
  alias VR.Taxonomy.{Label, Topic}

  # ── 조회 ─────────────────────────────────────────────────

  @doc "내 토픽. 정렬 순서 → 이름순."
  def list_topics(owner, opts \\ [])
  def list_topics(%Account{id: id}, opts), do: list_topics(id, opts)

  def list_topics(owner_id, _opts) when is_binary(owner_id) do
    Repo.all(
      from t in Topic,
        where: t.owner_id == ^owner_id and is_nil(t.deleted_at),
        order_by: [asc: t.sort_order, asc: t.name]
    )
  end

  @doc "내 라벨. 이름순."
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
  토픽별 회의 수를 함께 준다. 관리 화면이 "이걸 지우면 몇 개가 풀리는지" 를 보여줘야 한다.

  삭제된 회의는 세지 않는다.
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

  @doc "내 토픽 하나. **남의 것이면 nil** — 없는 것과 구별되지 않아야 한다."
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
  회의 목록을 그릴 때 쓰는 일괄 해석.

  **삭제된 분류도 돌려준다.** 아직 회의에 남아 있는 참조를 이름 없이
  그리면 화면에 정체불명의 칩이 뜬다.
  """
  def resolve_for(meetings) when is_list(meetings) do
    topic_ids = meetings |> Enum.map(& &1.topic_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    label_ids = meetings |> Enum.flat_map(&(&1.label_ids || [])) |> Enum.uniq()

    %{
      topics: fetch_by_ids(Topic, topic_ids),
      labels: fetch_by_ids(Label, label_ids)
    }
  end

  # ── 생성 · 수정 ──────────────────────────────────────────

  @doc "토픽을 만든다. 정렬 순서는 맨 뒤로 붙인다."
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

  # ── 삭제 ─────────────────────────────────────────────────

  @doc """
  토픽을 지우고 쓰던 회의에서 떼어낸다. 한 트랜잭션이다.

  몇 개가 풀렸는지 돌려준다 — 사용자가 되돌릴지 판단할 근거다.
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

  @doc "라벨을 지우고 회의의 `label_ids` 에서 **그 id 만** 뺀다."
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

  # ── 정렬 ─────────────────────────────────────────────────

  @doc """
  토픽 순서를 바꾼다. **전체 목록을 통째로** 받는다.

  부분 재정렬을 받으면 빠진 것들의 순서를 서버가 추측해야 하고,
  두 창에서 동시에 옮기면 순서가 어긋난 채로 남는다.
  하나라도 내 것이 아니거나 개수가 다르면 **아무것도 바꾸지 않는다.**
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

  # ── 회의에 붙일 때 ───────────────────────────────────────

  @doc """
  회의에 붙일 수 있는 값인가. **회의 owner 의 분류만** 허용한다.

  Contributor 가 자기 라벨을 남의 회의에 붙이면, owner 의 아카이브 검색에서
  그 회의가 자기 분류로 걸리지 않는다. 붙인 사람만 아는 분류가 된다.
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

  # ── 내부 ─────────────────────────────────────────────────

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
