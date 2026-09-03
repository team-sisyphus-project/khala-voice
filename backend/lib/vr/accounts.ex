defmodule VR.Accounts do
  @moduledoc """
  Accounts, sessions, and email tokens.

  ## Security principles

  1. **Tokens are stored as hashes.** The original exists only in cookies and email links.
  2. **Never leak whether an account exists.** Failed logins and password reset requests
     produce the same response and similar timing whether or not the account exists.
  3. **Changing the password revokes all other sessions.** This reliably invalidates hijacked sessions.
  4. **Login attempts are counted.** Rate-limited per email and per IP separately.
  """

  import Ecto.Query, warn: false

  alias VR.Accounts.{Account, AccountSession, AccountToken, InviteCode, LoginAttempt}
  alias VR.Config
  alias VR.Repo

  # Lock out when failures within the last 15 minutes exceed these values
  @max_failures_per_email 10
  @max_failures_per_ip 30
  @failure_window_minutes 15

  # ── Lookup ───────────────────────────────────────────────

  def get_account(id), do: Repo.one(active_query() |> where([a], a.id == ^id))

  def get_account!(id), do: Repo.one!(active_query() |> where([a], a.id == ^id))

  def get_account_by_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()
    Repo.one(active_query() |> where([a], a.email == ^normalized))
  end

  def get_account_by_email(_), do: nil

  def get_account_by_social(provider, social_id) do
    Repo.one(
      active_query()
      |> where([a], a.social_provider == ^provider and a.social_id == ^social_id)
    )
  end

  defp active_query, do: from(a in Account, where: is_nil(a.deleted_at))

  @doc """
  Finds an account by email + password.

  Even when the account does not exist, a dummy bcrypt verification is performed
  to keep response times consistent.
  """
  def get_account_by_email_and_password(email, password) do
    account = get_account_by_email(email)

    if Account.valid_password?(account || %Account{}, password), do: account
  end

  # ── Registration ─────────────────────────────────────────

  @doc """
  Registration.

  When `policy.invite_code_required` is enabled, a valid invite code is required.
  Code verification, account creation, and code consumption are wrapped in
  **a single transaction** to prevent two accounts from being created with the same code.
  """
  def register_account(attrs) do
    result =
      if invite_required?() do
        register_with_invite(attrs)
      else
        %Account{} |> Account.registration_changeset(attrs) |> Repo.insert()
      end

    # Auto-subscribe to the free plan. Registration succeeds even if this fails —
    # incomplete billing setup must not keep users out.
    with {:ok, account} <- result do
      VR.Billing.ensure_default_subscription(account.id)
      {:ok, account}
    end
  end

  defp invite_required?, do: Config.fetch("policy.invite_code_required") == true

  defp register_with_invite(attrs) do
    code = attrs[:invite_code] || attrs["invite_code"]

    Ecto.Multi.new()
    |> Ecto.Multi.run(:invite, fn _repo, _ ->
      case claimable_invite(code) do
        nil -> {:error, :invalid_invite_code}
        invite -> {:ok, invite}
      end
    end)
    |> Ecto.Multi.insert(:account, Account.registration_changeset(%Account{}, attrs))
    |> Ecto.Multi.run(:consume, fn repo, %{invite: invite, account: account} ->
      # Re-check status in the condition so concurrent requests cannot use the same code
      case repo.update_all(
             from(i in InviteCode, where: i.id == ^invite.id and i.status == "available"),
             set: [
               status: "used",
               used_by_account_id: account.id,
               used_at: DateTime.utc_now(:second)
             ]
           ) do
        {1, _} -> {:ok, :consumed}
        {0, _} -> {:error, :invite_code_taken}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} ->
        {:ok, account}

      {:error, :invite, reason, _} ->
        {:error,
         %Account{}
         |> Account.registration_changeset(attrs, hash_password: false)
         |> Ecto.Changeset.add_error(:invite_code, invite_error_message(reason))}

      {:error, :consume, _reason, _} ->
        {:error,
         %Account{}
         |> Account.registration_changeset(attrs, hash_password: false)
         |> Ecto.Changeset.add_error(:invite_code, "This code was just used by someone else. Please enter a different code.")}

      {:error, :account, changeset, _} ->
        {:error, changeset}
    end
  end

  defp invite_error_message(:invalid_invite_code), do: "is not a valid invite code"
  defp invite_error_message(_), do: "please check the invite code"

  defp claimable_invite(nil), do: nil
  defp claimable_invite(""), do: nil

  defp claimable_invite(code) do
    normalized = code |> to_string() |> String.trim() |> String.upcase()
    now = DateTime.utc_now(:second)

    Repo.one(
      from i in InviteCode,
        where:
          i.code == ^normalized and i.status == "available" and
            (is_nil(i.expires_at) or i.expires_at > ^now)
    )
  end

  @doc "Issues an invite code."
  def create_invite_code(attrs \\ %{}) do
    attrs |> InviteCode.build() |> Repo.insert()
  end

  def list_invite_codes(opts \\ []) do
    query = from i in InviteCode, order_by: [desc: i.inserted_at]
    query = if opts[:status], do: where(query, [i], i.status == ^opts[:status]), else: query
    Repo.all(query)
  end

  def change_account_registration(account \\ %Account{}, attrs \\ %{}) do
    Account.registration_changeset(account, attrs, hash_password: false)
  end

  @doc """
  Finds or creates a user arriving via social login.

  1. Look up by `(provider, social ID)`
  2. If not found, look up an existing account by email and **link** it
     (the same person may have registered with a password first)
  3. If that also fails, create a new one
  """
  def find_or_create_social_account(provider, social_id, attrs) do
    cond do
      account = get_account_by_social(provider, social_id) ->
        {:ok, account}

      account = attrs[:email] && get_account_by_email(attrs[:email]) ->
        account
        |> Ecto.Changeset.change(%{social_provider: provider, social_id: social_id})
        |> Repo.update()

      true ->
        result =
          %Account{}
          |> Account.social_registration_changeset(
            Map.merge(attrs, %{social_provider: provider, social_id: social_id})
          )
          |> Repo.insert()

        with {:ok, account} <- result do
          VR.Billing.ensure_default_subscription(account.id)
          {:ok, account}
        end
    end
  end

  # ── Profile and password ─────────────────────────────────

  def update_profile(%Account{} = account, attrs) do
    account |> Account.profile_changeset(attrs) |> Repo.update()
  end

  @doc "Changes only the theme. Used to save immediately without going through the settings screen."
  def update_theme(%Account{} = account, theme) do
    account |> Account.theme_changeset(theme) |> Repo.update()
  end

  @doc """
  Changes only the UI display language (`locale`). Used to save immediately without going through the settings screen.

  **Distinct from the transcription language (`transcribe_language`).** It is common to
  use the app in English while recording meetings in Korean — coupling the two would
  force users to change both every time.
  """
  def update_locale(%Account{} = account, locale) do
    account |> Account.locale_changeset(locale) |> Repo.update()
  end

  @doc """
  Changes the default transcription language. `nil` reverts to automatic (browser language).

  **Distinct from the UI language (`locale`).** It is common to use the app in Korean
  while recording meetings in English — coupling the two would force users to change
  the UI language every time as well.
  """
  def update_transcribe_language(%Account{} = account, language) do
    account |> Account.transcribe_language_changeset(language) |> Repo.update()
  end

  @doc """
  Changes the password and **revokes all other sessions.**

  Only the session specified by `keep_session_id` remains (the browser currently in use).
  """
  def update_password(%Account{} = account, attrs, opts \\ []) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:account, Account.password_changeset(account, attrs))
    |> Ecto.Multi.run(:sessions, fn _repo, _changes ->
      {count, _} = revoke_other_sessions(account.id, opts[:keep_session_id])
      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, :account, changeset, _} -> {:error, changeset}
    end
  end

  # ── Sessions ─────────────────────────────────────────────

  @doc "Login. Returns `{raw_token, session}`. The raw token is planted only in the cookie."
  def create_session(%Account{} = account, attrs \\ %{}) do
    {token, changeset} = AccountSession.build(account.id, attrs)

    case Repo.insert(changeset) do
      {:ok, session} -> {:ok, token, session}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Records the server-verified MFA success time on the current login session."
  def mark_session_mfa_verified(%AccountSession{account_id: account_id} = session, account_id) do
    session
    |> Ecto.Changeset.change(%{mfa_verified_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  def mark_session_mfa_verified(%AccountSession{}, _account_id), do: {:error, :session_mismatch}

  @doc """
  Finds an account by session token. If valid, refreshes the last activity time.

  If an account scheduled for deletion logs in, the schedule is **canceled.**
  """
  def get_account_by_session_token(token) when is_binary(token) do
    with {:ok, hash} <- AccountSession.hash_token(token),
         %AccountSession{} = session <- find_live_session(hash),
         %Account{} = account <- get_account(session.account_id) do
      touch_session(session)
      {:ok, account, session}
    else
      _ -> :error
    end
  end

  def get_account_by_session_token(_), do: :error

  defp find_live_session(hash) do
    now = DateTime.utc_now(:second)

    Repo.one(
      from s in AccountSession,
        where: s.token_hash == ^hash and s.is_active == true and s.expires_at > ^now
    )
  end

  defp touch_session(session) do
    now = DateTime.utc_now(:second)

    # Skip the write if it was already refreshed within the last minute (avoid an UPDATE per request)
    if DateTime.diff(now, session.last_activity_at || now, :second) >= 60 do
      Repo.update_all(
        from(s in AccountSession, where: s.id == ^session.id),
        set: [last_activity_at: now]
      )
    end
  end

  def list_sessions(account_id) do
    now = DateTime.utc_now(:second)

    Repo.all(
      from s in AccountSession,
        where: s.account_id == ^account_id and s.is_active == true and s.expires_at > ^now,
        order_by: [desc: s.last_activity_at]
    )
  end

  def revoke_session(token) when is_binary(token) do
    case AccountSession.hash_token(token) do
      {:ok, hash} ->
        Repo.update_all(
          from(s in AccountSession, where: s.token_hash == ^hash),
          set: [is_active: false]
        )

        :ok

      :error ->
        :ok
    end
  end

  def revoke_session_by_id(account_id, session_id) do
    Repo.update_all(
      from(s in AccountSession, where: s.account_id == ^account_id and s.id == ^session_id),
      set: [is_active: false]
    )

    :ok
  end

  def revoke_other_sessions(account_id, keep_session_id) do
    query =
      from s in AccountSession,
        where: s.account_id == ^account_id and s.is_active == true

    query =
      if keep_session_id, do: where(query, [s], s.id != ^keep_session_id), else: query

    Repo.update_all(query, set: [is_active: false])
  end

  def revoke_all_sessions(account_id), do: revoke_other_sessions(account_id, nil)

  # ── Email tokens ─────────────────────────────────────────

  @doc "Creates a one-time token. Returns the raw string — used only in email links."
  def create_email_token(%Account{} = account, context, sent_to \\ nil) do
    {token, changeset} = AccountToken.build(account.id, context, sent_to || account.email)

    case Repo.insert(changeset) do
      {:ok, _} -> {:ok, token}
      error -> error
    end
  end

  @doc "Verifies the token and **immediately marks it consumed.** The same token cannot be used twice."
  def consume_email_token(token, context) when is_binary(token) do
    now = DateTime.utc_now(:second)

    with {:ok, hash} <- AccountToken.hash_token(token),
         %AccountToken{} = record <-
           Repo.one(
             from t in AccountToken,
               where:
                 t.token_hash == ^hash and t.context == ^context and
                   t.expires_at > ^now and is_nil(t.used_at)
           ),
         {1, _} <-
           Repo.update_all(
             from(t in AccountToken, where: t.id == ^record.id and is_nil(t.used_at)),
             set: [used_at: now]
           ),
         %Account{} = account <- get_account(record.account_id) do
      {:ok, account, record}
    else
      _ -> :error
    end
  end

  def consume_email_token(_token, _context), do: :error

  @doc "Marks email confirmation as complete."
  def confirm_account(token) do
    case consume_email_token(token, "confirm") do
      {:ok, account, _} ->
        account |> Account.confirm_changeset() |> Repo.update()

      :error ->
        :error
    end
  end

  @doc "Changes the password using a reset token and revokes all sessions."
  def reset_password(token, attrs) do
    case consume_email_token(token, "reset_password") do
      {:ok, account, _} ->
        update_password(account, attrs, keep_session_id: nil)

      :error ->
        :error
    end
  end

  # ── Login attempt rate limiting ──────────────────────────

  def record_login_attempt(email, ip, success?) do
    %LoginAttempt{}
    |> LoginAttempt.changeset(%{email: email, ip_address: ip, success: success?})
    |> Repo.insert()
  end

  @doc """
  Whether a login attempt is allowed right now.

  Recent failures are counted per email and per IP separately.
  """
  def login_allowed?(email, ip) do
    since = DateTime.add(DateTime.utc_now(:second), -@failure_window_minutes, :minute)

    email_failures = count_failures(:email, email, since)
    ip_failures = count_failures(:ip_address, ip, since)

    cond do
      email_failures >= @max_failures_per_email -> {:error, :too_many_attempts}
      ip_failures >= @max_failures_per_ip -> {:error, :too_many_attempts}
      true -> :ok
    end
  end

  defp count_failures(_field, nil, _since), do: 0

  defp count_failures(:email, value, since) do
    normalized = value |> to_string() |> String.trim() |> String.downcase()

    Repo.aggregate(
      from(a in LoginAttempt,
        where: a.email == ^normalized and a.success == false and a.attempted_at > ^since
      ),
      :count
    )
  end

  defp count_failures(:ip_address, value, since) do
    Repo.aggregate(
      from(a in LoginAttempt,
        where: a.ip_address == ^value and a.success == false and a.attempted_at > ^since
      ),
      :count
    )
  end

  @doc "Clears the failure records for that email on successful login."
  def clear_failures(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()
    Repo.delete_all(from a in LoginAttempt, where: a.email == ^normalized and a.success == false)
    :ok
  end

  # ── Scheduled deletion ───────────────────────────────────

  @doc "Schedules account deletion. After the grace period, the DeletionWorker handles it."
  def schedule_deletion(%Account{} = account) do
    at = DateTime.add(DateTime.utc_now(:second), Account.deletion_grace_days(), :day)

    result =
      account
      |> Ecto.Changeset.change(%{scheduled_deletion_at: at})
      |> Repo.update()

    # Revoke all sessions at the same time as scheduling
    with {:ok, _} <- result, do: revoke_all_sessions(account.id)

    result
  end

  @doc "Cancels scheduled deletion. Called automatically when the user logs in within the grace period."
  def cancel_deletion(%Account{scheduled_deletion_at: nil} = account), do: {:ok, account}

  def cancel_deletion(%Account{} = account) do
    account
    |> Ecto.Changeset.change(%{scheduled_deletion_at: nil})
    |> Repo.update()
  end
end
