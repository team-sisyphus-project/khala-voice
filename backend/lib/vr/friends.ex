defmodule VR.Friends do
  @moduledoc """
  친구 관계와 초대.

  이 앱에서 친구 목록은 sisyphus의 "프로젝트 멤버" 자리를 대신한다.
  회의의 Reviewer/Contributor 지정, 화자 매핑, 공개 범위(`all_friends`)가
  전부 여기를 본다.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias VR.Accounts
  alias VR.Accounts.Account
  alias VR.Friends.{FriendInvitation, Friendship}
  alias VR.Repo

  # ── 친구 목록 ────────────────────────────────────────────

  @doc "내 친구 계정 목록 (차단된 관계 제외)."
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

  @doc "두 계정이 친구인가. 권한 판정(`all_friends` 범위)에서 쓴다."
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

  @doc "친구 관계를 만든다. 이미 있으면 그대로 돌려준다."
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
      # 차단한 사람만 풀 수 있다
      %Friendship{blocked_by_id: blocker} = f when blocker == account_id ->
        f |> Friendship.unblock_changeset() |> Repo.update()

      %Friendship{} ->
        {:error, :not_blocker}

      nil ->
        {:error, :not_found}
    end
  end

  # ── 초대 ─────────────────────────────────────────────────

  @doc """
  초대를 만든다. `email`이 있으면 이메일 초대, 없으면 링크 초대다.

  `{:ok, invitation, 원본_토큰}`을 돌려준다. 토큰은 링크에만 쓴다.
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

  @doc "내가 보낸 초대."
  def list_sent_invitations(account_id) do
    Repo.all(
      from i in FriendInvitation,
        where: i.invited_by_id == ^account_id,
        order_by: [desc: i.inserted_at]
    )
  end

  @doc "내 이메일로 온 대기 중인 초대."
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
  토큰으로 초대를 조회한다. 로그인하지 않은 사람도 볼 수 있어야 한다
  (초대 링크를 열면 누가 초대했는지 보여줘야 하므로).
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
  초대를 수락한다. 초대 상태 변경과 친구 관계 생성을 **한 트랜잭션**으로 묶는다.
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

  @doc "초대자가 자기 초대를 취소한다."
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

  @doc "만료된 초대를 정리한다. 주기 작업에서 호출한다."
  def expire_stale_invitations do
    now = DateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(i in FriendInvitation, where: i.status == "pending" and i.expires_at <= ^now),
        set: [status: "expired", updated_at: now]
      )

    count
  end

  # ── 내부 검증 ────────────────────────────────────────────

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
