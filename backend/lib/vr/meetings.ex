defmodule VR.Meetings do
  @moduledoc """
  회의와 녹음 세션.

  ## 권한

  조회·수정 함수는 **계정을 함께 받아** 권한을 계산한다.
  권한이 없으면 `{:error, :not_found}` — 403이 아니라 404로 응답하기 위해서다.
  존재 여부 자체를 노출하지 않는다.
  """

  import Ecto.Query, warn: false

  alias VR.Access.AccessLevel
  alias VR.Accounts.Account
  alias VR.Friends
  alias VR.Meetings.{Meeting, RecordingSession}
  alias VR.Repo
  alias VR.Taxonomy

  # ── 권한 ─────────────────────────────────────────────────

  @doc "이 계정이 이 회의에 대해 갖는 권한 레벨."
  @spec level(Meeting.t(), Account.t() | nil, keyword()) :: AccessLevel.level()
  def level(%Meeting{} = meeting, account, opts \\ []) do
    AccessLevel.resolve(
      meeting,
      account && account.id,
      Keyword.merge(
        [
          is_admin: account && account.is_admin,
          friends?: &Friends.friends?/2
        ],
        opts
      )
    )
  end

  @doc "최소 권한을 만족하면 회의를 준다. 아니면 `{:error, :not_found}`."
  @spec authorize(String.t(), Account.t() | nil, AccessLevel.level(), keyword()) ::
          {:ok, Meeting.t(), AccessLevel.level()} | {:error, :not_found}
  def authorize(meeting_id, account, required, opts \\ []) do
    with %Meeting{} = meeting <- get_meeting(meeting_id),
         lvl <- level(meeting, account, opts),
         true <- AccessLevel.at_least?(lvl, required) do
      {:ok, meeting, lvl}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── 회의 ─────────────────────────────────────────────────

  def get_meeting(id) when is_binary(id) do
    Repo.one(from m in Meeting, where: m.id == ^id and is_nil(m.deleted_at))
  end

  def get_meeting(_), do: nil

  def get_meeting_with_sessions(id) do
    case get_meeting(id) do
      nil -> nil
      meeting -> %{meeting | recording_sessions: list_sessions(meeting.id)}
    end
  end

  @doc """
  내가 볼 수 있는 회의 목록.

  Reviewer·Contributor 인 것과, 친구 공개 범위로 열린 것을 합친다.
  친구 목록을 매번 조인하지 않고 미리 뽑아 `IN` 으로 넣는다 —
  친구 수는 많아야 수백이라 이쪽이 단순하고 빠르다.
  """
  def list_meetings(%Account{} = account, opts \\ []) do
    account
    |> base_query()
    |> apply_filters(opts)
    |> apply_order(opts[:order])
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
    |> Repo.all()
  end

  @doc """
  같은 조건의 전체 개수. 필터 화면이 "N개" 를 보여주려면 필요하다.

  **목록과 같은 술어를 쓴다.** 복붙하면 반드시 어긋난다.
  """
  def count_meetings(%Account{} = account, opts \\ []) do
    account
    |> base_query()
    |> apply_filters(opts)
    |> exclude(:order_by)
    |> select([m], count(m.id))
    |> Repo.one()
  end

  # 내가 볼 수 있는 회의.
  #
  # **`owner_id` 를 넣지 않는다.** `AccessLevel.resolve/3` 가 owner 를 보지 않기 때문이다.
  # 넣으면 Reviewer 를 남에게 넘긴 회의가 **목록엔 보이는데 열면 404** 가 된다.
  # 반대로 `resolve` 에 owner 를 넣으면 양도 자체가 무의미해진다.
  defp base_query(%Account{} = account) do
    friend_ids = Enum.map(Friends.list_friends(account.id), & &1.id)

    from m in Meeting,
      where: is_nil(m.deleted_at),
      where:
        m.reviewer_id == ^account.id or
          ^account.id in m.contributor_ids or
          (m.reviewer_id in ^friend_ids and
             fragment("? #>> '{view,mode}' = ?", m.permissions, "all_friends")) or
          fragment("? #> '{view,accountIds}' @> ?", m.permissions, ^[account.id])
  end

  defp apply_filters(query, opts) do
    query
    |> filter_status(opts[:status])
    |> filter_topic(opts[:topic_id])
    |> filter_labels(opts[:label_ids], opts[:label_mode])
    |> filter_period(opts[:from], opts[:to])
    |> filter_participant(opts[:participant_id])
    |> filter_query(opts[:q])
  end

  # 아카이브 화면은 보관한 순서로 본다
  defp apply_order(query, "archived_desc"),
    do: order_by(query, [m], desc_nulls_last: m.archived_at, desc: m.inserted_at)

  defp apply_order(query, _default),
    do: order_by(query, [m], desc: m.started_at, desc: m.inserted_at)

  # 기본은 아카이브를 숨긴다. 아카이브 검색 화면에서만 명시적으로 켠다.
  defp filter_status(query, nil), do: where(query, [m], m.status != "archived")
  defp filter_status(query, "all"), do: query
  defp filter_status(query, status), do: where(query, [m], m.status == ^status)

  defp filter_topic(query, nil), do: query
  defp filter_topic(query, topic_id), do: where(query, [m], m.topic_id == ^topic_id)

  defp filter_labels(query, nil, _mode), do: query
  defp filter_labels(query, [], _mode), do: query

  # 배열 파라미터의 타입을 명시한다. `^ids` 만 쓰면 Postgrex 가 타입을 추론하지 못해
  # 쿼리가 통째로 실패할 수 있다.
  defp filter_labels(query, ids, "or"),
    do: where(query, [m], fragment("? && ?", m.label_ids, type(^ids, {:array, :string})))

  defp filter_labels(query, ids, _and),
    do: where(query, [m], fragment("? @> ?", m.label_ids, type(^ids, {:array, :string})))

  # 특정 인물이 낀 회의. **출처: sisyphus** `lib/sisyphus/archives.ex` 의 참여자 필터 —
  # 조직·author 개념을 걷어내고 Reviewer / owner / Contributor 세 자리로 줄였다.
  defp filter_participant(query, nil), do: query
  defp filter_participant(query, ""), do: query

  defp filter_participant(query, account_id),
    do:
      where(
        query,
        [m],
        m.reviewer_id == ^account_id or m.owner_id == ^account_id or
          ^account_id in m.contributor_ids
      )

  defp filter_period(query, nil, nil), do: query
  defp filter_period(query, from, nil), do: where(query, [m], m.started_at >= ^from)
  defp filter_period(query, nil, to), do: where(query, [m], m.started_at <= ^to)

  defp filter_period(query, from, to),
    do: where(query, [m], m.started_at >= ^from and m.started_at <= ^to)

  defp filter_query(query, nil), do: query
  defp filter_query(query, ""), do: query

  # `%` 와 `_` 를 이스케이프한다. 안 하면 사용자가 `%` 한 글자를 쳤을 때
  # 전체가 매치돼 "검색했는데 전부 나온다" 가 된다.
  # PostgreSQL 의 LIKE 기본 이스케이프 문자가 백슬래시라 ESCAPE 절이 필요 없다.
  defp filter_query(query, q) do
    pattern = "%" <> escape_like(q) <> "%"

    where(
      query,
      [m],
      ilike(m.title, ^pattern) or ilike(m.description, ^pattern) or ilike(m.summary, ^pattern)
    )
  end

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp maybe_limit(query, nil), do: limit(query, 50)
  defp maybe_limit(query, n), do: limit(query, ^n)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, 0), do: query
  defp maybe_offset(query, n), do: offset(query, ^n)

  @doc "회의를 만든다. 만든 사람이 Reviewer가 된다."
  def create_meeting(%Account{} = account, attrs \\ %{}) do
    attrs =
      attrs
      |> normalize()
      |> Map.put(:owner_id, account.id)
      |> Map.put(:reviewer_id, account.id)

    with :ok <- validate_taxonomy(account.id, attrs) do
      %Meeting{} |> Meeting.create_changeset(attrs) |> Repo.insert()
    end
  end

  def update_meeting(%Meeting{} = meeting, attrs) do
    attrs = normalize(attrs)

    with :ok <- validate_taxonomy(meeting.owner_id, attrs) do
      meeting |> Meeting.update_changeset(attrs) |> Repo.update()
    end
  end

  # 회의에 붙는 분류는 **회의 owner 의 것**이어야 한다.
  # Contributor 가 자기 라벨을 붙이면 owner 의 아카이브 검색에 걸리지 않는다.
  defp validate_taxonomy(owner_id, attrs) do
    if Map.has_key?(attrs, :topic_id) or Map.has_key?(attrs, :label_ids) do
      Taxonomy.validate_assignment(
        owner_id,
        Map.get(attrs, :topic_id),
        Map.get(attrs, :label_ids)
      )
    else
      :ok
    end
  end

  @doc """
  요약 결과를 저장한다.

  실패 기록만 남기는 경우(`last_summary_error` 만 전달)에도 같은 경로를 쓴다 —
  기존 `summary_data` 를 지우지 않기 위해서다.
  """
  def update_summary(%Meeting{} = meeting, attrs) do
    meeting |> Meeting.summary_changeset(normalize(attrs)) |> Repo.update()
  end

  def update_permissions(%Meeting{} = meeting, attrs) do
    meeting |> Meeting.permissions_changeset(normalize(attrs)) |> Repo.update()
  end

  def set_status(%Meeting{} = meeting, status) do
    meeting |> Meeting.status_changeset(status) |> Repo.update()
  end

  def delete_meeting(%Meeting{} = meeting) do
    meeting
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  @doc "세션 합계를 다시 계산해 회의에 캐시한다."
  def recalculate_totals(%Meeting{} = meeting) do
    %{duration: duration, credits: credits} =
      Repo.one(
        from s in RecordingSession,
          where: s.meeting_id == ^meeting.id and is_nil(s.deleted_at),
          select: %{
            duration: coalesce(sum(s.duration_seconds), 0),
            credits: coalesce(sum(s.credits_charged), 0)
          }
      )

    meeting
    |> Meeting.totals_changeset(duration, credits)
    |> Repo.update()
  end

  # ── 녹음 세션 ────────────────────────────────────────────

  def list_sessions(meeting_id) do
    Repo.all(
      from s in RecordingSession,
        where: s.meeting_id == ^meeting_id and is_nil(s.deleted_at),
        order_by: [asc: s.session_index, asc: s.started_at_unix]
    )
  end

  @doc """
  아직 전사가 끝나지 않은 세션이 남아 있는가.

  긴 회의는 20분마다 쪼개져 세션이 여럿이 되고, 청크마다 몇 분씩 시차를 두고
  끝난다. **하나라도 남아 있으면 요약을 시작하면 안 된다** — 먼저 끝난 청크만으로
  만든 반쪽 요약이 저장되고, 나중 청크의 자동 요약은 "이미 요약이 있음"으로
  건너뛰어 영영 갱신되지 않는다. 사용자가 [다시 요약]으로 크레딧을 한 번 더
  써야 온전한 요약을 얻는다.
  """
  def transcription_pending?(meeting_id) when is_binary(meeting_id) do
    Repo.exists?(
      from s in RecordingSession,
        where: s.meeting_id == ^meeting_id and is_nil(s.deleted_at),
        where: s.status in ^~w(recording uploaded splitting transcribing)
    )
  end

  def get_session(id) when is_binary(id) do
    Repo.one(from s in RecordingSession, where: s.id == ^id and is_nil(s.deleted_at))
  end

  def get_session(_), do: nil

  @doc """
  녹음 세션을 만든다.

  `session_index`는 회의 안에서 이어 붙인다. 유니크 제약이 걸려 있어
  동시 요청이 같은 번호를 받으면 하나가 실패한다 — 그때 한 번 다시 시도한다.
  """
  def create_session(%Meeting{} = meeting, attrs \\ %{}) do
    do_create_session(meeting, normalize(attrs), 0)
  end

  defp do_create_session(_meeting, _attrs, retries) when retries > 3,
    do: {:error, :session_index_conflict}

  defp do_create_session(meeting, attrs, retries) do
    index = next_session_index(meeting.id)
    attrs = attrs |> Map.put(:meeting_id, meeting.id) |> Map.put(:session_index, index)

    case %RecordingSession{} |> RecordingSession.create_changeset(attrs) |> Repo.insert() do
      {:ok, session} ->
        {:ok, session}

      {:error, %{errors: errors}} = error ->
        if Keyword.has_key?(errors, :meeting_id) or Keyword.has_key?(errors, :session_index) do
          do_create_session(meeting, attrs, retries + 1)
        else
          error
        end
    end
  end

  defp next_session_index(meeting_id) do
    max =
      Repo.one(
        from s in RecordingSession,
          where: s.meeting_id == ^meeting_id,
          select: max(s.session_index)
      )

    (max || 0) + 1
  end

  @doc """
  업로드 완료 등록.

  `audio_url` 은 **서버가 `storage_key` 에서 만든다.** 클라이언트가 보낸 값은 버린다 —
  그 값이 전사 워커의 다운로드로 들어가므로 믿으면 SSRF 가 된다.
  """
  def register_upload(%RecordingSession{} = session, attrs) do
    session
    |> RecordingSession.upload_changeset(normalize(attrs))
    |> put_audio_url(session)
    # changeset 이 아니라 여기서 검증한다 — 값을 채우는 것이 컨텍스트이기 때문이다
    |> Ecto.Changeset.validate_required([:audio_url])
    |> Repo.update()
  end

  defp put_audio_url(changeset, %RecordingSession{storage_key: key}) when is_binary(key) do
    Ecto.Changeset.put_change(changeset, :audio_url, VR.Storage.public_url(key))
  end

  # presign 을 거치지 않은 세션(개발용 시드 등)은 키가 없다. 그대로 둔다.
  defp put_audio_url(changeset, _session), do: changeset

  @doc "presign 단계에서 서버가 정한 저장 키를 기록한다."
  def set_storage_key(%RecordingSession{} = session, key) do
    session |> RecordingSession.storage_key_changeset(key) |> Repo.update()
  end

  def set_session_status(%RecordingSession{} = session, status, attrs \\ %{}) do
    session |> RecordingSession.status_changeset(status, normalize(attrs)) |> Repo.update()
  end

  def update_transcript(%RecordingSession{} = session, attrs) do
    session |> RecordingSession.transcript_changeset(normalize(attrs)) |> Repo.update()
  end

  def update_speaker_map(%RecordingSession{} = session, speaker_map) do
    session |> RecordingSession.speaker_map_changeset(speaker_map) |> Repo.update()
  end

  def delete_session(%RecordingSession{} = session) do
    session
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  # ── 내부 ─────────────────────────────────────────────────

  # 컨트롤러에서 오는 문자열 키와 내부 호출의 아톰 키를 모두 받는다
  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> Map.new(attrs, fn {k, v} -> {to_atom_safe(k), v} end)
  end

  defp to_atom_safe(k) when is_atom(k), do: k

  defp to_atom_safe(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> :__unknown__
  end
end
