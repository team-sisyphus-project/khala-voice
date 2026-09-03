defmodule VR.Workers.AdminAuditRetentionWorker do
  @moduledoc "Enforces the 365-day online retention policy for admin account audit events."

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    VR.AdminAudit.purge_expired()
    :ok
  end
end
