defmodule VR.Workers.CreditExpiryWorker do
  @moduledoc """
  만료된 크레딧 묶음을 정리한다.

  **출처: devkanban** `lib/manualsquad/billing/credit_expiry_worker.ex`.

  잔액 조회는 이미 만료 시각을 걸러 보므로 이 워커가 늦어도 잔액이 틀리지는 않는다.
  다만 **원장에 만료 기록이 남아야** 나중에 "왜 줄었나"를 되짚을 수 있다.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias VR.Billing.Credits

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case Credits.expire_due_lots() do
      0 -> :ok
      count -> Logger.info("[CreditExpiry] #{count}개 묶음을 만료 처리했습니다")
    end

    :ok
  end
end
