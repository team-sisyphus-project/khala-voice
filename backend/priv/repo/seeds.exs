# 개발·최초 설치용 시드.
#
#     mix run priv/repo/seeds.exs
#
# `mix ecto.setup` 이 자동으로 실행한다. 여러 번 돌려도 안전하다.
#
# **테스트 DB 에는 넣지 않는다.** 테스트는 빈 DB 를 전제로 자기 데이터를 만든다.
# `MIX_ENV=test mix ecto.reset` 이 시드까지 돌리면 무료 플랜이 중복돼
# 요금 테스트가 통째로 깨진다.

if Mix.env() == :test do
  IO.puts("[seeds] 테스트 환경에서는 시드를 넣지 않습니다")
  System.halt(0)
end

alias VR.Accounts.Admin
alias VR.Billing
alias VR.Billing.Credits

# ── 초기 어드민 ────────────────────────────────────────────
case Admin.ensure_bootstrap_admin() do
  {:ok, account, password} ->
    IO.puts("""

    ┌──────────────────────────────────────────────────────────┐
      초기 어드민 계정을 만들었습니다

        이메일    #{account.email}
        비밀번호  #{password}

      이 비밀번호는 지금만 볼 수 있습니다. 저장해 두세요.
      실사용자를 승격한 뒤 이 계정은 삭제하세요.
    └──────────────────────────────────────────────────────────┘
    """)

  {:error, :admin_exists} ->
    IO.puts("[seeds] 어드민이 이미 있습니다. 건너뜁니다.")

  {:error, :email_required} ->
    IO.puts("""
    [seeds] 초기 어드민을 건너뜁니다 — BOOTSTRAP_ADMIN_EMAIL 이 없습니다.

      BOOTSTRAP_ADMIN_EMAIL=you@example.com mix run priv/repo/seeds.exs
      또는  mix vr.bootstrap_admin --email you@example.com
    """)

  {:error, _changeset} ->
    IO.puts("[seeds] 초기 어드민을 만들지 못했습니다. mix vr.bootstrap_admin 을 실행해 보세요.")
end

# ── 크레딧 환산 정책 ───────────────────────────────────────
#
# 1 크레딧 = $N. 어드민에서 바꾼다.
# 기본값은 devkanban 의 참고값(Cookie Crate 기준 ≈ $0.0015)을 따랐다.
# 이 값이 없으면 사용량을 크레딧으로 바꿀 수 없어 전사·요약이 계량되지 않는다.
if is_nil(Credits.conversion_setting()) do
  {:ok, setting} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
  IO.puts("[seeds] 크레딧 환산 정책 생성 — 1 크레딧 = $#{setting.credit_value_usd}")
else
  IO.puts("[seeds] 크레딧 환산 정책이 이미 있습니다.")
end

# ── 무료 플랜 ──────────────────────────────────────────────
#
# 가입하면 자동으로 여기 구독된다. 포함 크레딧은 어드민에서 바꾼다
# (바꾸려면 새 리비전을 발행한다 — 기존 구독은 그랜드파더링된다).
case Billing.get_plan_by_key(Billing.free_plan_key()) do
  nil ->
    {:ok, plan} =
      Billing.create_plan(%{
        key: Billing.free_plan_key(),
        display_name: "무료",
        description: "회의를 녹음하고 전사·요약할 수 있습니다.",
        status: "published",
        publicly_listed: true,
        sort_order: 0
      })

    {:ok, revision} =
      Billing.publish_revision(plan, %{
        prices: %{"KRW" => %{"amount" => 0}, "USD" => %{"amount" => 0}},
        interval: "month",
        included_credits: 3_000,
        limits: %{}
      })

    IO.puts("[seeds] 무료 플랜 생성 — 월 #{revision.included_credits} 크레딧")

  _plan ->
    IO.puts("[seeds] 무료 플랜이 이미 있습니다.")
end
