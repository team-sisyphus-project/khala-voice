defmodule VR.Accounts.Admin do
  @moduledoc """
  Account management by system admins.

  ## Lockout prevention is the core of this module

  If the admin count reaches zero, **no one can enter `/_admin`.**
  Recovery requires touching the DB directly or running `mix vr.make_admin` on the server.

  Therefore, the following are **refused**:

  - Revoking the last admin's privileges
  - Deleting the last admin
  - Revoking your own privileges (prevents accidentally locking yourself out)
  - Deleting yourself

  To delete your own account, use "schedule account deletion" in the regular settings screen.
  The admin screen is **for managing other people's accounts.**

  ## Bootstrap account

  Right after installation there is no admin, so the entrance is blocked. That is why one
  is created automatically. Delete it after promoting a real user, and the entrance closes.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias VR.Accounts.{Account, AccountSession, AccountToken}
  alias VR.AdminAudit
  alias VR.Config
  alias VR.Friends.{FriendInvitation, Friendship}
  alias VR.Repo

  # ── Lookup ───────────────────────────────────────────────

  @doc """
  Account listing.

  ## Options
  - `:q` — partial match on email/name
  - `:only` — `:admins` | `:bootstrap` | `:deleted`
  - `:limit` — default 100
  """
  def list_accounts(opts \\ []) do
    query = from a in Account, order_by: [desc: a.is_admin, asc: a.email]

    query
    |> filter_deleted(opts[:only])
    |> filter_only(opts[:only])
    |> filter_query(opts[:q])
    |> limit(^(opts[:limit] || 100))
    |> Repo.all()
  end

  defp filter_deleted(query, :deleted), do: where(query, [a], not is_nil(a.deleted_at))
  defp filter_deleted(query, _), do: where(query, [a], is_nil(a.deleted_at))

  defp filter_only(query, :admins), do: where(query, [a], a.is_admin == true)
  defp filter_only(query, :bootstrap), do: where(query, [a], a.is_bootstrap == true)
  defp filter_only(query, _), do: query

  defp filter_query(query, nil), do: query
  defp filter_query(query, ""), do: query

  defp filter_query(query, q) do
    pattern = "%#{q}%"
    where(query, [a], ilike(a.email, ^pattern) or ilike(a.name, ^pattern))
  end

  @doc "Number of live admins. The basis for lockout-prevention decisions."
  def count_admins do
    Repo.aggregate(
      from(a in Account, where: a.is_admin == true and is_nil(a.deleted_at)),
      :count
    )
  end

  @doc "The bootstrap account still remaining, if any. When present, the admin screen recommends deleting it."
  def bootstrap_account do
    Repo.one(from a in Account, where: a.is_bootstrap == true and is_nil(a.deleted_at), limit: 1)
  end

  @doc "What an admin can do with a given account. Used by the UI to render buttons."
  def capabilities(%Account{} = target, %Account{} = actor) do
    self? = target.id == actor.id
    last_admin? = target.is_admin and count_admins() <= 1

    %{
      can_promote: not target.is_admin,
      can_demote: target.is_admin and not self? and not last_admin?,
      can_delete: not self? and not last_admin?,
      is_self: self?,
      is_last_admin: last_admin?
    }
  end

  # ── Privilege changes ────────────────────────────────────

  @doc "Promotes another account to admin."
  def promote(%Account{} = target, %Account{} = actor, session \\ nil) do
    cond do
      not actor.is_admin ->
        audited_result("admin.promote", target, actor, :unauthorized)

      not recent_mfa?(session, actor) ->
        audited_result("admin.promote", target, actor, :recent_mfa_required)

      target.deleted_at ->
        audited_result("admin.promote", target, actor, :account_deleted)

      target.is_admin ->
        audited_result("admin.promote", target, actor, :already_admin, {:ok, target})

      true ->
        set_admin(target, actor, true, "admin.promote")
    end
  end

  @doc """
  Revokes admin privileges.

  Refused for the last admin or for yourself.
  """
  def demote(%Account{} = target, %Account{} = actor, session \\ nil) do
    cond do
      not actor.is_admin ->
        audited_result("admin.demote", target, actor, :unauthorized)

      not recent_mfa?(session, actor) ->
        audited_result("admin.demote", target, actor, :recent_mfa_required)

      not target.is_admin ->
        audited_result("admin.demote", target, actor, :not_admin, {:ok, target})

      target.id == actor.id ->
        audited_result("admin.demote", target, actor, :cannot_demote_self)

      count_admins() <= 1 ->
        audited_result("admin.demote", target, actor, :last_admin)

      true ->
        set_admin(target, actor, false, "admin.demote")
    end
  end

  defp set_admin(target, actor, value, action) do
    Multi.new()
    |> Multi.update(:account, Ecto.Changeset.change(target, %{is_admin: value}))
    |> Multi.insert(
      :audit_event,
      audit_changeset(action, target, actor, "succeeded", "completed")
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{account: updated}} -> {:ok, updated}
      {:error, :audit_event, _reason, _changes} -> {:error, :audit_write_failed}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # ── Deletion ─────────────────────────────────────────────

  @doc """
  Deletes an account immediately (soft delete + anonymization).

  Unlike a regular user's "scheduled deletion", there is no grace period.
  The admin is deleting explicitly, so it is processed right away.

  Anonymizes the same way `DeletionWorker` does — keeping the email would defeat
  the purpose of deletion and also block re-registration with the same address.
  """
  def delete_account(%Account{} = target, %Account{} = actor, session \\ nil) do
    cond do
      not actor.is_admin ->
        audited_result("account.delete", target, actor, :unauthorized)

      not recent_mfa?(session, actor) ->
        audited_result("account.delete", target, actor, :recent_mfa_required)

      target.id == actor.id ->
        audited_result("account.delete", target, actor, :cannot_delete_self)

      target.is_admin and count_admins() <= 1 ->
        audited_result("account.delete", target, actor, :last_admin)

      target.deleted_at ->
        audited_result("account.delete", target, actor, :already_deleted)

      true ->
        do_delete(target, actor)
    end
  end

  @recent_mfa_seconds 10 * 60

  @doc "How long (in seconds) an MFA verification is honored for high-risk admin actions."
  def recent_mfa_seconds, do: @recent_mfa_seconds

  defp recent_mfa?(%AccountSession{id: session_id}, %Account{id: account_id}) do
    now = DateTime.utc_now(:second)
    cutoff = DateTime.add(now, -@recent_mfa_seconds, :second)

    Repo.exists?(
      from s in AccountSession,
        where:
          s.id == ^session_id and s.account_id == ^account_id and s.is_active == true and
            s.expires_at > ^now and s.mfa_verified_at >= ^cutoff and s.mfa_verified_at <= ^now
    )
  end

  defp recent_mfa?(_, _), do: false

  defp do_delete(target, actor) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.delete_all(:sessions, from(s in AccountSession, where: s.account_id == ^target.id))
    |> Multi.delete_all(:tokens, from(t in AccountToken, where: t.account_id == ^target.id))
    |> Multi.delete_all(
      :friendships,
      from(f in Friendship,
        where: f.account_a_id == ^target.id or f.account_b_id == ^target.id
      )
    )
    |> Multi.delete_all(
      :invitations,
      from(i in FriendInvitation, where: i.invited_by_id == ^target.id)
    )
    |> Multi.update(
      :account,
      Ecto.Changeset.change(target, %{
        deleted_at: now,
        email: "deleted+#{target.id}@deleted.invalid",
        name: nil,
        hashed_password: nil,
        social_provider: nil,
        social_id: nil,
        is_admin: false,
        is_bootstrap: false
      })
    )
    |> Multi.insert(
      :audit_event,
      audit_changeset("account.delete", target, actor, "succeeded", "completed")
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{account: deleted}} ->
        {:ok, deleted}

      {:error, :audit_event, _reason, _changes} ->
        {:error, :audit_write_failed}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  defp audited_result(action, target, actor, reason, result \\ nil) do
    outcome = if match?({:ok, _}, result), do: "succeeded", else: "denied"

    case AdminAudit.record(audit_attrs(action, target, actor, outcome, Atom.to_string(reason))) do
      {:ok, _event} -> result || {:error, reason}
      {:error, _changeset} -> {:error, :audit_write_failed}
    end
  end

  defp audit_changeset(action, target, actor, outcome, reason) do
    action
    |> audit_attrs(target, actor, outcome, reason)
    |> AdminAudit.changeset()
  end

  defp audit_attrs(action, target, actor, outcome, reason) do
    %{
      action: action,
      outcome: outcome,
      reason: reason,
      actor_account_id: actor.id,
      target_account_id: target.id,
      actor_email: actor.email,
      target_email: target.email
    }
  end

  # ── Bootstrap ────────────────────────────────────────────

  @doc """
  Creates the initial admin account. Does nothing if an admin already exists.

  `{:ok, account, password}` — the password is visible **only this once.**
  It is stored only as a hash and cannot be looked up later.

  The password is read from `app.bootstrap_admin_password` in the shared config layer,
  or generated randomly if absent. **No default password lives in the code** —
  this repo is public, so a default would give every deployment the same key.
  """
  def ensure_bootstrap_admin(opts \\ []) do
    if count_admins() > 0 do
      {:error, :admin_exists}
    else
      # No default email either. If every deployment used the same address,
      # that in itself would become an attack target.
      email = opts[:email] || Config.fetch("app.bootstrap_admin_email")

      password =
        opts[:password] || Config.fetch("app.bootstrap_admin_password") || random_password()

      if email in [nil, ""] do
        {:error, :email_required}
      else
        create_bootstrap(email, password)
      end
    end
  end

  defp create_bootstrap(email, password) do
    attrs = %{
      email: email,
      password: password,
      name: "Initial Admin"
    }

    changeset =
      %Account{}
      |> Account.registration_changeset(attrs)
      |> Ecto.Changeset.put_change(:is_admin, true)
      |> Ecto.Changeset.put_change(:is_bootstrap, true)
      # Must be usable immediately after login. Email delivery may not be configured yet.
      |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))

    case Repo.insert(changeset) do
      {:ok, account} -> {:ok, account, password}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Confusing characters (0/O/1/l/I) are excluded so it is easy for people to transcribe
  @alphabet ~c"abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  defp random_password do
    1..24
    |> Enum.map(fn _ -> Enum.random(@alphabet) end)
    |> List.to_string()
  end
end
