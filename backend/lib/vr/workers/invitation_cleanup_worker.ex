defmodule VR.Workers.InvitationCleanupWorker do
  @moduledoc "Marks stale friend invitations as expired."

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case VR.Friends.expire_stale_invitations() do
      0 -> :ok
      n -> Logger.info("[Invitations] marked #{n} as expired")
    end

    :ok
  end
end
