defmodule VR.Meetings do
  @moduledoc """
  Meetings and recording sessions.

  ## Permissions

  Read and update functions **take the account along** and compute permissions.
  Without permission, `{:error, :not_found}` — so we can respond with 404, not
  403. Existence itself is never exposed.
  """

  import Ecto.Query, warn: false

  alias VR.Access.AccessLevel
  alias VR.Accounts.Account
  alias VR.Friends
  alias VR.Meetings.{Meeting, RecordingSession}
  alias VR.Repo
  alias VR.Taxonomy

  # ── Permissions ──────────────────────────────────────────

  @doc "The permission level this account has for this meeting."
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

  @doc "Returns the meeting when the minimum permission is met. Otherwise `{:error, :not_found}`."
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

  # ── Meetings ─────────────────────────────────────────────

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
  The list of meetings I can see.

  Combines the ones where I am Reviewer or Contributor with the ones opened to
  friends. Instead of joining the friends list each time, we pre-fetch it and
  pass it via `IN` — a friends list is a few hundred at most, so this way is
  simpler and faster.
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
  The total count for the same conditions. Needed for the filter screen to show "N results".

  **Uses the same predicates as the list.** Copy-pasting them guarantees drift.
  """
  def count_meetings(%Account{} = account, opts \\ []) do
    account
    |> base_query()
    |> apply_filters(opts)
    |> exclude(:order_by)
    |> select([m], count(m.id))
    |> Repo.one()
  end

  # Meetings I can see.
  #
  # **Do not include `owner_id`.** `AccessLevel.resolve/3` does not look at the owner.
  # Including it makes a meeting whose Reviewer role was handed to someone else
  # **appear in the list but 404 when opened**. Conversely, teaching `resolve`
  # about the owner would make the handover itself meaningless.
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

  # The archive screen sorts by when items were archived
  defp apply_order(query, "archived_desc"),
    do: order_by(query, [m], desc_nulls_last: m.archived_at, desc: m.inserted_at)

  defp apply_order(query, _default),
    do: order_by(query, [m], desc: m.started_at, desc: m.inserted_at)

  # Archived meetings are hidden by default. Only the archive search screen turns them on explicitly.
  defp filter_status(query, nil), do: where(query, [m], m.status != "archived")
  defp filter_status(query, "all"), do: query
  defp filter_status(query, status), do: where(query, [m], m.status == ^status)

  defp filter_topic(query, nil), do: query
  defp filter_topic(query, topic_id), do: where(query, [m], m.topic_id == ^topic_id)

  defp filter_labels(query, nil, _mode), do: query
  defp filter_labels(query, [], _mode), do: query

  # Make the array parameter type explicit. With bare `^ids`, Postgrex may fail
  # to infer the type and the whole query can fail.
  defp filter_labels(query, ids, "or"),
    do: where(query, [m], fragment("? && ?", m.label_ids, type(^ids, {:array, :string})))

  defp filter_labels(query, ids, _and),
    do: where(query, [m], fragment("? @> ?", m.label_ids, type(^ids, {:array, :string})))

  # Meetings a given person is part of. **Source: sisyphus** — the participant filter
  # in `lib/sisyphus/archives.ex`, with the org/author concepts stripped and reduced
  # to the three seats Reviewer / owner / Contributor.
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

  # Escape `%` and `_`. Otherwise a user typing a single `%` matches everything —
  # "I searched and got every result".
  # PostgreSQL's default LIKE escape character is backslash, so no ESCAPE clause is needed.
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

  @doc "Create a meeting. The creator becomes the Reviewer."
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

  # Taxonomy attached to a meeting must belong to **the meeting's owner**.
  # If a Contributor attaches their own labels, the owner's archive search will not find them.
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
  Store a summary result.

  The same path is used when only recording a failure (passing just
  `last_summary_error`) — so the existing `summary_data` is not wiped.
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

  @doc "Recalculate session totals and cache them on the meeting."
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

  # ── Recording sessions ───────────────────────────────────

  def list_sessions(meeting_id) do
    Repo.all(
      from s in RecordingSession,
        where: s.meeting_id == ^meeting_id and is_nil(s.deleted_at),
        order_by: [asc: s.session_index, asc: s.started_at_unix]
    )
  end

  @doc """
  Are there sessions whose transcription has not finished yet?

  A long meeting is split every 20 minutes into multiple sessions, and each
  chunk finishes minutes apart. **If even one remains, summarization must not
  start** — a half summary built from only the chunks that finished first would
  be stored, and the later chunks' auto-summarization would skip with "a summary
  already exists" and never update it. The user would have to spend credits
  again via [Re-summarize] to get a complete summary.
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
  Create a recording session.

  `session_index` continues sequentially within a meeting. A unique constraint
  covers it, so if concurrent requests get the same number, one fails — and is
  then retried once.
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
  Register upload completion.

  `audio_url` is **built by the server from `storage_key`.** Whatever the client
  sent is discarded — that value feeds the transcription worker's download, so
  trusting it means SSRF.
  """
  def register_upload(%RecordingSession{} = session, attrs) do
    session
    |> RecordingSession.upload_changeset(normalize(attrs))
    |> put_audio_url(session)
    # Validated here rather than in the changeset — because the context is what fills the value in
    |> Ecto.Changeset.validate_required([:audio_url])
    |> Repo.update()
  end

  defp put_audio_url(changeset, %RecordingSession{storage_key: key}) when is_binary(key) do
    Ecto.Changeset.put_change(changeset, :audio_url, VR.Storage.public_url(key))
  end

  # Sessions that skipped presign (dev seeds, etc.) have no key. Leave them as is.
  defp put_audio_url(changeset, _session), do: changeset

  @doc "Record the storage key the server chose during the presign step."
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

  # ── Internal ─────────────────────────────────────────────

  # Accepts both string keys from controllers and atom keys from internal calls
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
