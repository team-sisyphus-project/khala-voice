defmodule VR.Sharing do
  @moduledoc """
  Shared links and guest sessions.

  **Source: sisyphus** `lib/sisyphus/shared_links.ex`. What changed:

  - **`consume_use/1` is a single conditional UPDATE.** The original checked with
    `valid?` and then incremented in a separate query, so concurrent requests
    could exceed `max_uses`.
  - **The use count only increases when a guest session is actually issued.** The
    original incremented on every link open, so a page refresh burned a one-time link.
  - `granted_role` and guest sessions were added.
  - The video-session-specific helpers and the `resource_type` branching were all removed.

  ## Revocation and exhaustion behave differently

  | | Guests already inside |
  |---|---|
  | **Revoke** (`revoke_link/1`) | **Cut off immediately** |
  | **Exhausted** (`max_uses` reached) | Remain as they are |

  Exhaustion means "no one else can enter", not "kick out whoever entered".
  If someone who received meeting notes through a one-time link got kicked out on
  their second request, the link would be useless. Revocation is the opposite —
  it only means something if it also cuts off whoever is viewing right now.

  ## Guest authorization goes through `guest_authorize/2` and nowhere else

  Controllers never pass `guest_role:` to `Meetings.authorize/4` directly.
  With multiple call sites, missing just one opens up a different meeting.
  """

  import Ecto.Query, warn: false

  alias VR.Access.AccessLevel
  alias VR.Accounts.Account
  alias VR.Config
  alias VR.Meetings
  alias VR.Meetings.Meeting
  alias VR.Repo
  alias VR.Sharing.{GuestSession, SharedLink, ShareAttempt}

  require Logger

  @ip_window_minutes 15
  @ip_max_failures 20

  # ── Issuance & management ────────────────────────────────
  # The caller settles authorization first via `Meetings.authorize(:lv0)`.

  @doc "Issues a link. **The plaintext token and PIN are only available here.**"
  def issue_link(%Meeting{} = meeting, %Account{} = actor, attrs \\ %{}) do
    {token, pincode, changeset} = SharedLink.build(meeting.id, actor.id, attrs)

    case Repo.insert(changeset) do
      {:ok, link} -> {:ok, link, token, pincode}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Lists a meeting's links. Excludes revoked ones, newest first."
  def list_links(meeting_id) when is_binary(meeting_id) do
    Repo.all(
      from l in SharedLink,
        where: l.meeting_id == ^meeting_id and is_nil(l.deleted_at),
        order_by: [desc: l.inserted_at]
    )
  end

  def get_link(id) when is_binary(id) do
    Repo.one(from l in SharedLink, where: l.id == ^id and is_nil(l.deleted_at))
  end

  def get_link(_), do: nil

  def update_link(%SharedLink{} = link, attrs) do
    link |> SharedLink.update_changeset(attrs) |> Repo.update()
  end

  @doc """
  Regenerates only the token. Settings and use count are kept, and **guests who
  already entered are not cut off** — they hold their own guest tokens, and a
  rotation means "the link URL was lost".
  """
  def rotate_token(%SharedLink{} = link) do
    {token, changeset} = SharedLink.rotate_changeset(link)

    case Repo.update(changeset) do
      {:ok, updated} -> {:ok, updated, token}
      error -> error
    end
  end

  @doc "Turns the PIN on or off. When turning on, returns the new PIN exactly once."
  def set_pincode(%SharedLink{} = link, mode) when mode in [:on, :off] do
    {pincode, changeset} = SharedLink.pin_changeset(link, mode)

    case Repo.update(changeset) do
      {:ok, updated} -> {:ok, updated, pincode}
      error -> error
    end
  end

  @doc """
  Revokes a link. **Guest sessions that entered through this link are cut off too.**

  sisyphus only flipped `is_active` off, and whoever had already entered stayed in.
  """
  def revoke_link(%SharedLink{} = link) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      updated =
        link
        |> Ecto.Changeset.change(%{is_active: false, revoked_at: now, deleted_at: now})
        |> Repo.update!()

      Repo.update_all(
        from(g in GuestSession, where: g.shared_link_id == ^link.id and is_nil(g.revoked_at)),
        set: [revoked_at: now]
      )

      updated
    end)
  end

  @doc "The share URL. Returns just the path if no app base URL is configured."
  def link_url(token) when is_binary(token) do
    case Config.fetch("app.base_url") do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/") <> "/share/" <> token

      _ ->
        "/share/" <> token
    end
  end

  # ── Guest entry ──────────────────────────────────────────

  @doc """
  Finds a link by its token. **Looks up by hash** — the plaintext is not in the DB.

  Revoked links are found too. To show the recipient "this link has ended" (410),
  we must distinguish it from a nonexistent one (404). Whether the link is usable
  is checked separately by `check_usable/1`.
  """
  def fetch_by_token(token) when is_binary(token) do
    with {:ok, hash} <- SharedLink.hash_token(token),
         %SharedLink{} = link <- Repo.one(from l in SharedLink, where: l.token_hash == ^hash) do
      {:ok, link}
    else
      _ -> {:error, :not_found}
    end
  end

  def fetch_by_token(_), do: {:error, :not_found}

  @doc """
  Can this link be entered right now?

  **The reason it cannot is never put in the response.** Saying whether it is
  expired or exhausted leaks the fact that the token was valid.
  """
  def check_usable(%SharedLink{} = link) do
    if SharedLink.usable?(link), do: :ok, else: {:error, :gone}
  end

  @doc """
  Verifies the PIN.

  Checks both the per-link lockout (5 attempts → 15 minutes) and the **per-IP
  lockout** (20 attempts per 15 minutes). With only the per-link lockout, an
  attacker alternating across multiple links cannot be stopped.
  """
  def verify_pincode(%SharedLink{} = link, pincode, ip \\ nil) do
    # **Re-read from the DB.** The struct the caller holds was read before this
    # request, so failure counts bumped by other requests are not reflected.
    # Using it as-is, N concurrent requests would all see "0 failures" and pass
    # the lockout.
    link = get_link(link.id) || link

    cond do
      SharedLink.pin_locked?(link) ->
        {:error, :locked}

      ip_locked?(ip) ->
        {:error, :locked}

      SharedLink.valid_pin?(link, pincode) ->
        record_attempt(link, ip, true)
        reset_failures(link)
        :ok

      true ->
        record_attempt(link, ip, false)
        bump_failures(link)
        {:error, :invalid_pincode}
    end
  end

  @doc """
  Burns one use. **The check and the increment are a single statement.**

  Checking and then incrementing separately would let two concurrent requests
  both pass the check, using a `max_uses: 1` link twice.
  """
  def consume_use(%SharedLink{} = link) do
    now = DateTime.utc_now(:second)

    query =
      from l in SharedLink,
        where: l.id == ^link.id,
        where: l.is_active and is_nil(l.deleted_at) and is_nil(l.revoked_at),
        where: is_nil(l.expires_at) or l.expires_at > ^now,
        where: is_nil(l.max_uses) or l.use_count < l.max_uses,
        select: l

    case Repo.update_all(query, inc: [use_count: 1], set: [last_used_at: now]) do
      {1, [updated]} -> {:ok, updated}
      _ -> {:error, :gone}
    end
  end

  @doc """
  Enters as a guest.

  ## A signed-in account never creates a guest session

  Account permissions win. Someone who is already a Contributor must not be
  demoted to Viewer for entering through a viewer link, and conversely the link's
  use count must not be burned because of them. So if there is an account, we
  **only route them to the meeting**.

  ## When `guest_link_enabled` is off, unauthenticated visitors cannot enter

  Even if the link is alive, guests are refused while the meeting-side switch is
  closed. This is also a **404** — we do not reveal that the link was valid.
  """
  def enter(token, params \\ %{}, opts \\ []) do
    with {:ok, link} <- fetch_by_token(token),
         :ok <- check_usable(link) do
      case opts[:account] do
        %Account{} = account -> enter_as_account(link, account, params, opts)
        _ -> enter_as_guest(link, params, opts)
      end
    end
  end

  defp enter_as_account(%SharedLink{} = link, %Account{} = account, params, opts) do
    case Meetings.authorize(link.meeting_id, account, :lv2) do
      # Already viewable via account permissions. The link is not used —
      # no PIN prompt and no use burned.
      {:ok, meeting, level} ->
        {:ok, %{mode: :account, meeting: meeting, level: level, guest_token: nil}}

      # Signed in, but no permission on that meeting. **Treated exactly like an
      # anonymous visitor** — the meeting switch is checked and the PIN is asked.
      # If merely being signed in skipped the gate, anyone could register an
      # account to bypass the guest block.
      {:error, :not_found} ->
        enter_as_guest(link, params, Keyword.put(opts, :account, account))
    end
  end

  defp enter_as_guest(%SharedLink{} = link, params, opts) do
    with :ok <- ensure_guest_link_enabled(link, opts),
         :ok <- verify_pincode(link, params["pincode"] || params[:pincode], opts[:ip_address]),
         {:ok, session_changeset} <- build_guest(link, params, opts),
         {:ok, link} <- consume_use(link) do
      {token, changeset} = session_changeset

      case Repo.insert(changeset) do
        {:ok, session} ->
          {:ok,
           %{
             mode: :guest,
             meeting_id: link.meeting_id,
             granted_role: session.granted_role,
             guest_token: token,
             expires_at: session.expires_at
           }}

        {:error, changeset} ->
          # A use was already burned. The session could not be created, so refund it.
          refund_use(link)
          {:error, changeset}
      end
    end
  end

  # The switch means "this meeting does not accept guests". **Sign-in status is
  # irrelevant.** If being signed in were an exemption, anyone could register to
  # bypass the block, and burn a one-time link on someone else's behalf so the
  # legitimate recipient could not enter.
  #
  # People who can already view via account permissions never reach this point
  # (`enter_as_account`).
  defp ensure_guest_link_enabled(%SharedLink{} = link, _opts) do
    # Not a 403. Also hides the fact that the link was valid.
    if guest_link_enabled?(link.meeting_id), do: :ok, else: {:error, :not_found}
  end

  defp guest_link_enabled?(meeting_id) do
    Repo.one(
      from m in Meeting,
        where: m.id == ^meeting_id and is_nil(m.deleted_at),
        select: m.guest_link_enabled
    ) == true
  end

  defp build_guest(link, params, opts) do
    attrs = %{
      display_name: params["display_name"] || params[:display_name],
      email: params["email"] || params[:email],
      account_id: opts[:account] && opts[:account].id,
      user_agent: opts[:user_agent],
      ip_address: opts[:ip_address]
    }

    {token, changeset} = GuestSession.build(link, attrs)

    if changeset.valid?,
      do: {:ok, {token, changeset}},
      else: {:error, %{changeset | action: :insert}}
  end

  # If session creation fails but the use count was burned, a one-time link
  # becomes unusable for everyone
  defp refund_use(%SharedLink{} = link) do
    Repo.update_all(
      from(l in SharedLink, where: l.id == ^link.id and l.use_count > 0),
      inc: [use_count: -1]
    )
  end

  # ── Guest sessions ───────────────────────────────────────

  @doc """
  Finds a session by its guest token. Expired or revoked ones are treated as
  nonexistent.

  On a hit, updates the last-activity timestamp.
  """
  def fetch_live_guest(token) when is_binary(token) do
    now = DateTime.utc_now(:second)

    with {:ok, hash} <- GuestSession.hash_token(token),
         %GuestSession{} = session <-
           Repo.one(
             from g in GuestSession,
               # **Re-checks on every request that the link is still alive.**
               # Looking only at the session, a Reviewer disabling the link or
               # pulling its expiry forward would let someone already inside keep
               # reading — the control they believe they flipped would do nothing.
               #
               # `max_uses` exhaustion is **deliberately excluded.** Exhaustion
               # means "no one else can enter", not "kick out whoever entered"
               # (see the revoke/exhaust distinction in the moduledoc).
               join: l in SharedLink,
               on: l.id == g.shared_link_id,
               where: g.token_hash == ^hash and is_nil(g.revoked_at) and g.expires_at > ^now,
               where: l.is_active and is_nil(l.deleted_at) and is_nil(l.revoked_at),
               where: is_nil(l.expires_at) or l.expires_at > ^now,
               select: g
           ) do
      Repo.update_all(
        from(g in GuestSession, where: g.id == ^session.id),
        set: [last_activity_at: now]
      )

      {:ok, session}
    else
      _ -> :error
    end
  end

  def fetch_live_guest(_), do: :error

  @doc "Revokes a guest session."
  def revoke_guest(%GuestSession{} = session) do
    session
    |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  @doc """
  Can this guest view this meeting at this level? **This is the only place guest
  authorization is decided.**

  The meeting is decided by the **session**, not the request — `session.meeting_id`
  is used. Even if the request points at a different meeting, the session's
  meeting wins.
  """
  def guest_authorize(%GuestSession{} = session, required) do
    with %Meeting{} = meeting <- Meetings.get_meeting(session.meeting_id),
         true <- guest_link_enabled?(meeting.id),
         level <-
           AccessLevel.resolve(meeting, nil,
             guest_role: session.granted_role,
             # Matched against the meeting the session is bound to. Without this
             # argument, AccessLevel returns lv3.
             guest_resource_id: session.meeting_id
           ),
         true <- AccessLevel.at_least?(level, required) do
      {:ok, meeting, level}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── Internal ─────────────────────────────────────────────

  defp record_attempt(%SharedLink{} = link, ip, success) do
    %ShareAttempt{}
    |> ShareAttempt.changeset(%{
      token_hash: link.token_hash,
      ip_address: ip && String.slice(to_string(ip), 0, 45),
      success: success
    })
    |> Repo.insert()
  end

  defp ip_locked?(nil), do: false

  defp ip_locked?(ip) do
    since = DateTime.add(DateTime.utc_now(:second), -@ip_window_minutes, :minute)

    count =
      Repo.one(
        from a in ShareAttempt,
          where: a.ip_address == ^to_string(ip) and not a.success and a.attempted_at > ^since,
          select: count(a.id)
      ) || 0

    count >= @ip_max_failures
  end

  # The increment and the lockout decision happen in **one UPDATE statement**.
  #
  # Read-then-write (+1) lets concurrent requests overwrite each other's
  # increments (lost update), collapsing the 5-attempt lockout. A 6-digit PIN
  # becomes brute-forceable at that point.
  defp bump_failures(%SharedLink{} = link) do
    max = SharedLink.pin_max_failures()
    until = DateTime.add(DateTime.utc_now(:second), SharedLink.pin_lock_minutes(), :minute)

    query =
      from l in SharedLink,
        where: l.id == ^link.id,
        update: [
          inc: [failed_pin_attempts: 1],
          set: [
            pin_locked_until:
              fragment(
                "CASE WHEN ? + 1 >= ? THEN ? ELSE ? END",
                l.failed_pin_attempts,
                ^max,
                ^until,
                l.pin_locked_until
              )
          ]
        ]

    Repo.update_all(query, [])
  end

  defp reset_failures(%SharedLink{failed_pin_attempts: 0, pin_locked_until: nil}), do: :ok

  defp reset_failures(%SharedLink{} = link) do
    link
    |> Ecto.Changeset.change(%{failed_pin_attempts: 0, pin_locked_until: nil})
    |> Repo.update()
  end
end
