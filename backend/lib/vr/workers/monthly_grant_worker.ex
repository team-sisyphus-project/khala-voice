defmodule VR.Workers.MonthlyGrantWorker do
  @moduledoc """
  Advances subscriptions whose period has ended to the next period and grants
  credits.

  **Source: devkanban** `lib/manualsquad/billing/monthly_grant_worker.ex`.

  Runs once a day. Grants are guarded by an `idempotency_key`, so running twice
  within the same period does not grant credits twice.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias VR.Billing

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    due = Billing.list_due_subscriptions()

    {ok, failed} =
      Enum.reduce(due, {0, 0}, fn subscription, {ok, failed} ->
        case Billing.advance_period(subscription) do
          {:ok, _} ->
            {ok + 1, failed}

          {:error, reason} ->
            # One failure does not stop the rest. It is retried on the next run.
            Logger.error("[MonthlyGrant] period advance failed: #{subscription.id} — #{inspect(reason)}")

            {ok, failed + 1}
        end
      end)

    if ok > 0 or failed > 0 do
      Logger.info("[MonthlyGrant] advanced #{ok}, failed #{failed}")
    end

    :ok
  end
end
