defmodule VR.Workers.DeletionWorker do
  @moduledoc """
  Actually deletes accounts whose scheduled deletion has come due. Runs at the
  top of every hour.

  ## For now, soft delete only

  Sets `deleted_at` and deletes sessions, tokens, and friendships. The row
  itself remains.

  Hard deletion that also removes meetings, audio, and transcripts comes after
  the meetings domain lands in M2. Deleting the account row before then would
  leave the remaining meetings ownerless.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias VR.Accounts.{Account, AccountSession, AccountToken}
  alias VR.Friends.{FriendInvitation, Friendship}
  alias VR.Repo

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now(:second)

    due =
      Repo.all(
        from a in Account,
          where:
            not is_nil(a.scheduled_deletion_at) and a.scheduled_deletion_at <= ^now and
              is_nil(a.deleted_at)
      )

    Enum.each(due, &delete_account/1)

    if due != [], do: Logger.info("[Deletion] processed deletion of #{length(due)} accounts")

    :ok
  end

  defp delete_account(%Account{} = account) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      Repo.delete_all(from s in AccountSession, where: s.account_id == ^account.id)
      Repo.delete_all(from t in AccountToken, where: t.account_id == ^account.id)

      Repo.delete_all(
        from f in Friendship,
          where: f.account_a_id == ^account.id or f.account_b_id == ^account.id
      )

      Repo.delete_all(from i in FriendInvitation, where: i.invited_by_id == ^account.id)

      # Anonymize the email. Keeping the original defeats the point of a
      # deletion request. This also avoids the unique constraint so the same
      # address can sign up again.
      anonymized = "deleted+#{account.id}@deleted.invalid"

      account
      |> Ecto.Changeset.change(%{
        deleted_at: now,
        email: anonymized,
        name: nil,
        hashed_password: nil,
        social_provider: nil,
        social_id: nil
      })
      |> Repo.update!()
    end)

    Logger.info("[Deletion] account deleted: #{account.id}")
  end
end
