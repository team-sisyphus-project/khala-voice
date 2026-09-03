defmodule VRWeb.API.BillingAPITest do
  use VRWeb.ConnCase, async: true

  import VR.AccountsFixtures

  alias VR.{Accounts, Billing}
  alias VR.Billing.Credits

  setup %{conn: conn} do
    account = account_fixture()
    {:ok, token, _} = Accounts.create_session(account)

    conn =
      conn
      |> Plug.Test.init_test_session(%{account_token: token})
      |> put_req_header("accept", "application/json")

    {:ok, _} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})

    %{conn: conn, account: account}
  end

  test "returns balance and usage history", %{conn: conn, account: account} do
    {:ok, _} = Credits.grant(account.id, 500, source: "admin_grant", reason: "test grant")

    {:ok, _} =
      Credits.charge_usage(account.id, Decimal.new("0.15"),
        charge_domain: "stt",
        reason: "3 min transcription",
        pricing_snapshot: %{"minutes" => 3, "cost_per_minute_usd" => "0.016"}
      )

    body = conn |> get(~p"/api/me/billing") |> json_response(200)

    assert body["balance"] == 500 - 100
    assert length(body["entries"]) == 2

    charge = Enum.find(body["entries"], &(&1["charge_domain"] == "stt"))
    assert charge["delta"] < 0
    # The evidence for "why this much was charged". It is the user's own usage — no reason to hide it.
    assert charge["pricing_snapshot"]["minutes"] == 3
    assert charge["usage_cost_usd"]
  end

  test "returns a negative balance as-is", %{conn: conn, account: account} do
    # Rounding up to 0 for display would make the next grant's shrinkage inexplicable
    {:ok, _} =
      Credits.charge_usage(account.id, Decimal.new("0.15"),
        charge_domain: "llm",
        reason: "summary"
      )

    body = conn |> get(~p"/api/me/billing") |> json_response(200)
    assert body["balance"] < 0
  end

  test "cannot view someone else's account", %{conn: conn, account: account} do
    other = account_fixture()
    {:ok, _} = Credits.grant(other.id, 9999, source: "admin_grant", reason: "someone else's")
    {:ok, _} = Credits.grant(account.id, 10, source: "admin_grant", reason: "mine")

    # No parameter accepts an account id at all. Whatever is passed, only mine comes back.
    body = conn |> get(~p"/api/me/billing?account_id=#{other.id}") |> json_response(200)

    assert body["balance"] == 10
  end

  test "limit has a cap", %{conn: conn, account: account} do
    for i <- 1..5 do
      {:ok, _} = Credits.grant(account.id, 1, source: "admin_grant", reason: "grant #{i}")
    end

    body = conn |> get(~p"/api/me/billing?limit=99999") |> json_response(200)
    assert length(body["entries"]) == 5

    body = conn |> get(~p"/api/me/billing?limit=2") |> json_response(200)
    assert length(body["entries"]) == 2
  end

  test "unauthenticated is 401" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> put_req_header("accept", "application/json")

    assert conn |> get(~p"/api/me/billing") |> json_response(401)
  end

  test "includes free-plan info", %{conn: conn, account: account} do
    {:ok, plan} =
      Billing.create_plan(%{
        key: "free",
        display_name: "Free",
        status: "published",
        publicly_listed: true
      })

    {:ok, revision} =
      Billing.publish_revision(plan, %{
        prices: %{"KRW" => %{"amount" => 0}},
        interval: "month",
        included_credits: 3000
      })

    {:ok, _} = Billing.subscribe(account.id, revision)

    body = conn |> get(~p"/api/me/billing") |> json_response(200)

    assert body["plan"]["display_name"] == "Free"
    assert body["plan"]["included_credits"] == 3000
    assert body["subscription"]["status"]
  end
end
