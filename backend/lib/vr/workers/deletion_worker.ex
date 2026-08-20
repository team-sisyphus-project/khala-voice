defmodule VR.Workers.DeletionWorker do
  @moduledoc """
  삭제 예약이 만료된 계정을 실제로 지운다. 매시 정각에 돈다.

  ## 지금은 소프트 삭제만 한다

  `deleted_at`을 찍고 세션·토큰·친구 관계를 지운다. 행 자체는 남긴다.

  회의·오디오·전사본까지 함께 지우는 하드 삭제는 M2에서 회의 도메인이 생긴 뒤
  붙인다. 그전에 계정 행을 지우면 남은 회의가 주인 없는 상태가 된다.
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

    if due != [], do: Logger.info("[Deletion] #{length(due)}개 계정을 삭제 처리했습니다")

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

      # 이메일을 익명화한다. 원본을 남기면 삭제 요청의 의미가 없다.
      # 같은 주소로 다시 가입할 수 있도록 유니크 제약도 피한다.
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

    Logger.info("[Deletion] 계정 삭제 완료: #{account.id}")
  end
end
