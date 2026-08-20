defmodule VR.Workers.InvitationCleanupWorker do
  @moduledoc "만료된 친구 초대를 expired 로 표시한다."

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case VR.Friends.expire_stale_invitations() do
      0 -> :ok
      n -> Logger.info("[Invitations] #{n}건을 만료 처리했습니다")
    end

    :ok
  end
end
