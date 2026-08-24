defmodule VR.Workers.AdminAuditRetentionWorker do
  @moduledoc "관리자 계정 감사 이벤트의 365일 온라인 보존 정책을 집행한다."

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    VR.AdminAudit.purge_expired()
    :ok
  end
end
