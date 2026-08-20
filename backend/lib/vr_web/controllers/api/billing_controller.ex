defmodule VRWeb.API.BillingController do
  @moduledoc """
  내 요금 상태. **자기 것만 본다** — 계정 id 를 파라미터로 받지 않는다.

  받으면 남의 id 를 넣어보는 경로가 생긴다. `current_account` 만 쓴다.
  """

  use VRWeb, :controller

  alias VR.Billing
  alias VR.Billing.Credits
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  def show(conn, params) do
    account = conn.assigns.current_account
    summary = Billing.account_summary(account.id)

    json(conn, %{
      balance: summary.balance,
      plan: summary.plan && JSONView.plan(summary.plan, summary.revision),
      subscription: summary.subscription && JSONView.subscription(summary.subscription),
      lots: Enum.map(summary.lots, &JSONView.credit_lot/1),
      entries:
        account.id
        |> Credits.list_ledger(limit: parse_limit(params["limit"]))
        |> Enum.map(&JSONView.ledger_entry/1)
    })
  end

  # 화면이 보여줄 수 있는 만큼만. 상한을 두지 않으면 원장 전체를 한 번에 끌어온다.
  defp parse_limit(nil), do: 50

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> min(n, 200)
      _ -> 50
    end
  end

  defp parse_limit(_), do: 50
end
