defmodule VR.Friends do
  @moduledoc """
  Friendships and invitations.

  In this app, the friends list takes the place of sisyphus's "project members".
  Meeting Reviewer/Contributor assignment, speaker mapping, and visibility scope
  (`all_friends`) all look here.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias VR.Accounts
  alias VR.Accounts.Account
  alias VR.Friends.{FriendInvitation, Friendship}
  alias VR.Repo

  # ── Friends list ─────────────────────────────────────────

  @doc "The accounts of my friends (excluding blocked relationships)."
  def list_friends(account_id) do
    Repo.all(
      from a in Account,
        join: f in Friendship,
        on:
          (f.account_a_id == ^account_id and f.account_b_id == a.id) or
            (f.account_b_id == ^account_id and f.account_a_id == a.id),
        where: f.status == "active" and is_nil(a.deleted_at),
        order_by: [asc: a.name, asc: a.email]
    )
  end

  @doc "Whether two accounts are friends. Used in permission checks (the `all_friends` scope)."
  def friends?(nil, _other), do: false
  def friends?(_account_id, nil), do: false
  def friends?(same, same), do: false

  def friends?(account_id, other_id) do
    {a, b} = Friendship.order_pair(account_id, other_id)

    Repo.exists?(
      from f in Friendship,
        where: f.account_a_id == ^a and f.account_b_id == ^b and f.status == "active"
    )
  end

  def get_friendship(account_id, other_id) do
    {a, b} = Friendship.order_pair(account_id, other_id)
    Repo.one(from f in Friendship, where: f.account_a_id == ^a and f.account_b_id == ^b)
  end

  @doc "Creates a friendship. Returns the existing one if it already exists."
  def create_friendship(account_id, other_id) do
    case get_friendship(account_id, other_id) do
      nil -> account_id |> Friendship.build(other_id) |> Repo.insert()
      existing -> {:ok, existing}
    end
  end

  def remove_friend(account_id, other_id) do
    case get_friendship(account_id, other_id) do
      nil -> {:error, :not_found}
      friendship -> Repo.delete(friendship)
    end
  end

  def block(account_id, other_id) do
    case get_friendship(account_id, other_id) do
      nil -> {:error, :not_found}
      f -> f |> Friendship.block_changeset(account_id) |> Repo.update()
    end
  end

  def unblock(account_id, other_id) do
    case get_friendship(account_id, other_id) do
      # Only the person who blocked can unblock
      %Friendship{blocked_by_id: blocker} = f when blocker == account_id ->
        f |> Friendship.unblock_changeset() |> Repo.update()

      %Friendship{} ->
        {:error, :not_blocker}

      nil ->
        {:error, :not_found}
    end
  end

  # ── Invitations ──────────────────────────────────────────

  @doc """
  Creates an invitation. With `email` it is an email invitation; without, a link invitation.

  Returns `{:ok, invitation, raw_token}`. The token is used only in the link.
  """
  def create_invitation(%Account{} = inviter, attrs \\ %{}) do
    email = normalize_email(attrs[:email] || attrs["email"])

    with :ok <- check_not_self(inviter, email),
         :ok <- check_not_already_friends(inviter, email),
         :ok <- check_no_pending(inviter, email) do
      {token, changeset} = FriendInvitation.build(inviter.id, attrs)

      case Repo.insert(changeset) do
        {:ok, invitation} -> {:ok, invitation, token}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc "Invitations I have sent."
  def list_sent_invitations(account_id) do
    Repo.all(
      from i in FriendInvitation,
        where: i.invited_by_id == ^account_id,
        order_by: [desc: i.inserted_at]
    )
  end

  @doc "Pending invitations sent to my email address."
  def list_received_invitations(%Account{} = account) do
    now = DateTime.utc_now(:second)

    Repo.all(
      from i in FriendInvitation,
        where:
          i.email == ^account.email and i.status == "pending" and i.expires_at > ^now and
            i.invited_by_id != ^account.id,
        order_by: [desc: i.inserted_at]
    )
  end

  @doc """
  Looks up an invitation by token. Must be visible even to people who are not
  logged in (opening an invitation link should show who sent the invite).
  """
  def get_invitation_by_token(token) do
    now = DateTime.utc_now(:second)

    with {:ok, hash} <- FriendInvitation.hash_token(token),
         %FriendInvitation{} = invitation <-
           Repo.one(from i in FriendInvitation, where: i.token_hash == ^hash) do
      cond do
        invitation.status != "pending" -> {:error, :not_pending}
        DateTime.compare(invitation.expires_at, now) != :gt -> {:error, :expired}
        true -> {:ok, invitation}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Accepts an invitation. Bundles the invitation status change and friendship
  creation into **one transaction.**
  """
  def accept_invitation(token, %Account{} = account) do
    with {:ok, invitation} <- get_invitation_by_token(token),
         :ok <- check_not_inviter(invitation, account) do
      Multi.new()
      |> Multi.update(
        :invitation,
        FriendInvitation.respond_changeset(invitation, "accepted", account.id)
      )
      |> Multi.run(:friendship, fn _repo, _changes ->
        create_friendship(invitation.invited_by_id, account.id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{friendship: friendship}} -> {:ok, friendship}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  def decline_invitation(token, %Account{} = account) do
    with {:ok, invitation} <- get_invitation_by_token(token) do
      invitation
      |> FriendInvitation.respond_changeset("declined", account.id)
      |> Repo.update()
    end
  end

  @doc "The inviter cancels their own invitation."
  def cancel_invitation(invitation_id, %Account{} = account) do
    case Repo.get(FriendInvitation, invitation_id) do
      %FriendInvitation{invited_by_id: owner} = invitation when owner == account.id ->
        invitation |> FriendInvitation.respond_changeset("cancelled") |> Repo.update()

      %FriendInvitation{} ->
        {:error, :not_owner}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Cleans up expired invitations. Called from a periodic job."
  def expire_stale_invitations do
    now = DateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(i in FriendInvitation, where: i.status == "pending" and i.expires_at <= ^now),
        set: [status: "expired", updated_at: now]
      )

    count
  end

  # ── Internal validation ──────────────────────────────────

  defp normalize_email(nil), do: nil
  defp normalize_email(""), do: nil
  defp normalize_email(v), do: v |> to_string() |> String.trim() |> String.downcase()

  defp check_not_self(_inviter, nil), do: :ok

  defp check_not_self(%Account{email: email}, email), do: {:error, :cannot_invite_self}
  defp check_not_self(_inviter, _email), do: :ok

  defp check_not_already_friends(_inviter, nil), do: :ok

  defp check_not_already_friends(inviter, email) do
    case Accounts.get_account_by_email(email) do
      nil ->
        :ok

      %Account{id: id} ->
        if friends?(inviter.id, id), do: {:error, :already_friends}, else: :ok
    end
  end

  defp check_no_pending(_inviter, nil), do: :ok

  defp check_no_pending(inviter, email) do
    now = DateTime.utc_now(:second)

    exists? =
      Repo.exists?(
        from i in FriendInvitation,
          where:
            i.invited_by_id == ^inviter.id and i.email == ^email and
              i.status == "pending" and i.expires_at > ^now
      )

    if exists?, do: {:error, :already_invited}, else: :ok
  end

  defp check_not_inviter(%FriendInvitation{invited_by_id: id}, %Account{id: id}),
    do: {:error, :cannot_accept_own}

  defp check_not_inviter(_invitation, _account), do: :ok
end
