defmodule VR.Workers.MonthlyGrantWorker do
  @moduledoc """
  기간이 끝난 구독을 다음 기간으로 넘기고 크레딧을 지급한다.

  **출처: devkanban** `lib/manualsquad/billing/monthly_grant_worker.ex`.

  하루 한 번 돈다. 지급은 `idempotency_key` 로 막혀 있어
  같은 기간에 두 번 실행돼도 크레딧이 두 번 들어가지 않는다.
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
            # 하나가 실패해도 나머지는 처리한다. 다음 실행에서 다시 시도된다.
            Logger.error("[MonthlyGrant] 기간 갱신 실패: #{subscription.id} — #{inspect(reason)}")

            {ok, failed + 1}
        end
      end)

    if ok > 0 or failed > 0 do
      Logger.info("[MonthlyGrant] 갱신 #{ok}건, 실패 #{failed}건")
    end

    :ok
  end
end
