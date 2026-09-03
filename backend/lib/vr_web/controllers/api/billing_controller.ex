defmodule VRWeb.API.BillingController do
  @moduledoc """
  My billing status. **Self only** — no account id is accepted as a parameter.

  Accepting one would create a path for probing other people's ids. Only
  `current_account` is used.
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

  # Only as much as the UI can show. Without a cap, the entire ledger would be pulled at once.
  defp parse_limit(nil), do: 50

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> min(n, 200)
      _ -> 50
    end
  end

  defp parse_limit(_), do: 50
end
