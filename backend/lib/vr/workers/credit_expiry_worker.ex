defmodule VR.Workers.CreditExpiryWorker do
  @moduledoc """
  Cleans up expired credit lots.

  **Source: devkanban** `lib/manualsquad/billing/credit_expiry_worker.ex`.

  Balance queries already filter by expiry time, so even if this worker runs
  late the balance is never wrong. But **the ledger must record the expiry** for
  "why did it drop" to be traceable later.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias VR.Billing.Credits

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case Credits.expire_due_lots() do
      0 -> :ok
      count -> Logger.info("[CreditExpiry] expired #{count} lots")
    end

    :ok
  end
end
