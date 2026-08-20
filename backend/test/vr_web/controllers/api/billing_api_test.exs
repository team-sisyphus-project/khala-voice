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

  test "잔액과 사용 내역을 준다", %{conn: conn, account: account} do
    {:ok, _} = Credits.grant(account.id, 500, source: "admin_grant", reason: "테스트 지급")

    {:ok, _} =
      Credits.charge_usage(account.id, Decimal.new("0.15"),
        charge_domain: "stt",
        reason: "전사 3분",
        pricing_snapshot: %{"minutes" => 3, "cost_per_minute_usd" => "0.016"}
      )

    body = conn |> get(~p"/api/me/billing") |> json_response(200)

    assert body["balance"] == 500 - 100
    assert length(body["entries"]) == 2

    charge = Enum.find(body["entries"], &(&1["charge_domain"] == "stt"))
    assert charge["delta"] < 0
    # "왜 이만큼 나갔나" 의 근거. 자기 사용 내역이라 숨길 이유가 없다.
    assert charge["pricing_snapshot"]["minutes"] == 3
    assert charge["usage_cost_usd"]
  end

  test "음수 잔액을 그대로 준다", %{conn: conn, account: account} do
    # 0 으로 반올림해 보여주면 다음 지급분이 왜 줄었는지 설명할 수 없다
    {:ok, _} =
      Credits.charge_usage(account.id, Decimal.new("0.15"),
        charge_domain: "llm",
        reason: "요약"
      )

    body = conn |> get(~p"/api/me/billing") |> json_response(200)
    assert body["balance"] < 0
  end

  test "남의 계정을 볼 수 없다", %{conn: conn, account: account} do
    other = account_fixture()
    {:ok, _} = Credits.grant(other.id, 9999, source: "admin_grant", reason: "남의 것")
    {:ok, _} = Credits.grant(account.id, 10, source: "admin_grant", reason: "내 것")

    # 계정 id 를 받는 파라미터 자체가 없다. 무엇을 넣어도 내 것만 나온다.
    body = conn |> get(~p"/api/me/billing?account_id=#{other.id}") |> json_response(200)

    assert body["balance"] == 10
  end

  test "limit 에 상한이 있다", %{conn: conn, account: account} do
    for i <- 1..5 do
      {:ok, _} = Credits.grant(account.id, 1, source: "admin_grant", reason: "지급 #{i}")
    end

    body = conn |> get(~p"/api/me/billing?limit=99999") |> json_response(200)
    assert length(body["entries"]) == 5

    body = conn |> get(~p"/api/me/billing?limit=2") |> json_response(200)
    assert length(body["entries"]) == 2
  end

  test "비로그인은 401" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> put_req_header("accept", "application/json")

    assert conn |> get(~p"/api/me/billing") |> json_response(401)
  end

  test "무료 플랜 정보를 함께 준다", %{conn: conn, account: account} do
    {:ok, plan} =
      Billing.create_plan(%{
        key: "free",
        display_name: "무료",
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

    assert body["plan"]["display_name"] == "무료"
    assert body["plan"]["included_credits"] == 3000
    assert body["subscription"]["status"]
  end
end
