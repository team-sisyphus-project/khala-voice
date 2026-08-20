# 06. 구독 · 크레딧

> **출처: devkanban.** 요금 정책과 관련된 모든 구조는 `devkanban` 리포에서 가져왔다.
> 설계 원칙은 `docs/billing-commerce-design.md`, 구현은 `lib/manualsquad/billing/*` 참조.
> 무엇이 어떻게 바뀌었는지는 [14-provenance.md](14-provenance.md#요금-정책--06-billingmd) 에 정리했다.

지금은 무료 플랜만 있고 실제 결제는 없다. 그래도 **집계는 정확히 돌린다.**

## 설계 원칙 (devkanban `billing-commerce-design.md` §2)

1. **카탈로그와 계약을 분리한다.** 상품 정의(`Plan`)와 계정이 가진 계약(`Subscription`)을
   나누고, 구독은 특정 `PlanRevision` 을 **핀 고정**한다. 가격을 바꾸면 새 리비전이
   발행되고 기존 구독은 자기 리비전을 유지한다 (그랜드파더링 자동).
2. **원장은 append-only.** 잔액은 절대 직접 수정하지 않고 증감 기록의 합으로 도출한다.
3. **결제 제공자는 중립.** `provider` + `external_id` 컬럼만 두고 연동은 나중에.
4. 플랜 월 지급은 기간 말 만료(이월 없음). 관리자 지급은 명시적 만료가 없으면 무기한.
5. **회수는 잔액을 음수로 만들 수 없다.**

---

## 카탈로그

### Plan — 가변 메타
> devkanban `lib/manualsquad/billing/plan.ex`

```elixir
key              # "free" — 코드에서 참조하는 키
status           # draft | published | deprecated | retired
display_name, description, name_i18n, description_i18n
icon, sort_order, publicly_listed
```

메타 수정은 **즉시 전원에게 반영**된다. 리비전을 만들지 않는다.

### PlanRevision — 불변 상업 스냅샷
> devkanban `lib/manualsquad/billing/plan_revision.ex`

```elixir
revision           :integer
prices             :map      # %{"KRW" => %{amount: 0}, "USD" => %{amount: 0}} (minor unit)
interval           # month | year
included_credits   :integer  # ★ 플랜이 매 기간 지급하는 크레딧
limits             :map
purchasable        :boolean
published_at
```

**가격 · 포함 크레딧 · 한도를 바꾸면 새 리비전을 발행한다.**
발행 시 이전 리비전은 `purchasable = false` 가 되고, 기존 구독은 영향받지 않는다.

#### 지급량 계산 — `granted_credits/1`
> devkanban `plan_revision.ex:102`

```elixir
# 크레딧 팩이 연결돼 있으면 팩 기준
granted_credits(%{credit_pack_revision: pack}) -> pack.credits + pack.bonus_credits
# 아니면 플랜의 included_credits
granted_credits(%{included_credits: n}) -> n
granted_credits(_) -> 0
```

**플랜은 크레딧을 기본으로 준다.** 구독이 활성인 동안 `MonthlyGrantWorker` 가
매 기간 `included_credits` 만큼 지급하고, 그 크레딧은 기간 말에 만료된다(이월 없음).

### Subscription
> devkanban `lib/manualsquad/billing/subscription.ex`

```elixir
account_id                # devkanban 은 organization_id
plan_revision_id          # 핀 고정
state                     # active | past_due | paused | canceled
current_period_start / current_period_end
cancel_at, scheduled_change
provider, provider_subscription_id   # 결제 연동 자리
```

계정당 활성 구독 1개. **가입 시 자동으로 Free 플랜 최신 리비전에 구독**시킨다.

---

## 크레딧

### CreditLot — 지급 묶음
> devkanban `lib/manualsquad/billing/credit_lot.ex`

```elixir
account_id
source        # plan_grant | admin_grant
amount        # 지급량
remaining     # 잔량 (음수 가능 — 오버드래프트)
expires_at    # nil = 무기한
origin        :map
```

### CreditLedgerEntry — append-only
> devkanban `lib/manualsquad/billing/credit_ledger_entry.ex`

```elixir
account_id
delta             # +지급 / -사용
source            # plan_grant | admin_grant | usage | expiry | admin_revoke | adjustment
reason, actor_id, credit_lot_id
idempotency_key   # unique — 중복 적용 방지

# 사용(usage) 상세 — 나중에 재계산할 수 있게 스냅샷을 남긴다
charge_domain     # "stt" | "llm"
usage_cost_usd    :decimal
credit_value_usd  :decimal
computed_credits  :decimal   # 반올림 전
charged_credits   :integer   # 실제 기록값
rounding_policy   # "ceil"
pricing_snapshot  :map
```

### 불변식

```
잔액 = Σ ledger.delta = Σ lot.remaining
```

- **소비 순서: 만료 임박 순 → FIFO.** 만료되는 플랜 크레딧을 먼저 쓰고 무기한을 나중에
- **관리자 회수는 잔액 이하로만** 가능
- **사용량 계량은 오버드래프트 허용** — 작업이 이미 끝난 뒤에 계량되므로 막을 수 없다.
  부족분은 `remaining` 이 음수인 묶음으로 기록해 위 불변식을 유지한다

### 멱등성
> devkanban `usage_idempotency_key/2`

한 번의 사용이 여러 묶음에 걸치면 원장 항목도 여러 개가 된다.
`idempotency_key` 는 unique 이므로 항목마다 파생시킨다.

| 항목 | 파생 열쇠 |
|---|---|
| 묶음에서 차감 | `<base>:lot:<credit_lot_id>` |
| 부족분 (오버드래프트) | `<base>:overdraft` |

**오버드래프트에는 묶음 id 를 쓰지 않는다.** 부족분을 기록할 때마다 새 묶음이 생기므로
열쇠가 매번 달라지고, 유니크 제약이 영영 걸리지 않는다. 그러면 워커가 재시도될 때마다
같은 사용이 다시 차감된다. **무료 플랜은 잔액 0 이 기본 상태**라 이 경로가 정상 경로다 —
즉 이 실수는 드문 예외가 아니라 모든 사용자에게 매번 일어난다.

회귀 테스트: `test/vr/billing_test.exs` — "사용량 계량 idempotency"

---

## 사용량 → 크레딧 환산

> **출처: devkanban** `lib/manualsquad/billing/credit_conversion_setting.ex` +
> `credit_conversions.ex`. **sisyphus 방식(서비스별 `cookie_rate`)을 쓰지 않는다.**

### CreditConversionSetting — 싱글턴

```elixir
singleton_key     "current"   # 항상 하나
currency          "USD"
credit_value_usd  :decimal    # 1 크레딧 = $N
rounding_policy   "ceil"      # 항상 올림
```

### 공식

```
computed_credits = usage_cost_usd / credit_value_usd
charged_credits  = ceil(computed_credits)
```

**왜 이 방식인가** — sisyphus 는 서비스마다 `cookie_rate` 를 따로 뒀다.
그러면 제공자 단가가 바뀔 때마다 서비스별 환산율을 다시 계산해야 한다.
devkanban 방식은 **실제 USD 원가에서 파생**되므로 단가가 바뀌어도
원가 계산만 고치면 되고, 크레딧 정책은 한 곳(`credit_value_usd`)에만 있다.

**올림(ceil)인 이유** — 정책이 하나뿐이라 단순하고, 소수점 이하를 흘리지 않는다.
devkanban 도 `rounding_policies` 를 `["ceil"]` 하나로 못박아 뒀다.

### 원가 산출

환산의 입력인 `usage_cost_usd` 는 이 앱이 직접 계산한다.

| 대상 | 원가 |
|---|---|
| 전사 | `ceil(duration_seconds / 60)` 분 × 분당 STT 단가 |
| 요약 | (입력 토큰 × 입력 단가 + 출력 토큰 × 출력 단가) / 1M |

단가는 어드민에서 관리한다 → [07-config-admin.md](07-config-admin.md)

---

## 무료 플랜 정책

| 항목 | 값 |
|---|---|
| Free 플랜 `included_credits` | **매 기간 지급** (어드민에서 정한다) |
| 소진 시 | `policy.hard_stop_on_zero_credits` 가 꺼져 있으면 계속 동작 (오버드래프트) |
| 사용자 화면 | 잔액 · 사용 내역 표시 |

**지금 실질 과금이 0인 이유**는 API 키를 시스템 어드민이 넣기 때문이지,
크레딧을 안 주기 때문이 아니다. 원장에는 정확한 사용량과 원가가 쌓이므로
어드민에서 실사용을 볼 수 있다.

**유료화할 때** 바꿀 것:
1. 유료 플랜 발행 (`Plan` + `PlanRevision` 추가)
2. Free 플랜의 `included_credits` 를 무료 한도로 조정
3. `policy.hard_stop_on_zero_credits` **ON** — 잔액 부족 시 신규 요청 거부
4. 결제 연동

스키마 변경 없이 진행된다.

---

## 워커

> devkanban `billing/monthly_grant_worker.ex`, `billing/credit_expiry_worker.ex`

| 워커 | 주기 | 동작 |
|---|---|---|
| `MonthlyGrantWorker` | 매일 | 활성 구독마다 `granted_credits` 를 `current_period_end` 만료로 지급하고 기간을 넘김 |
| `CreditExpiryWorker` | 매일 | `expires_at` 지난 묶음을 만료 처리하고 `expiry` 원장 기록 |

---

## 대외 명칭

> devkanban `billing/commerce_settings.ex`

```elixir
CommerceSettings   # 싱글턴
  credit_term      %{singular: "쿠키", plural: "쿠키", icon: "cookie"}
  plan_term
  locale_overrides
```

내부 코드 · DB · 로그는 항상 `credit` 으로 쓰고, **화면 렌더링에서만** 이 용어를 적용한다.

---

## 감사

> devkanban `billing/billing_audit_log.ex`

```elixir
actor_id, action, target_type, target_id, before, after, inserted_at
```

대상: 플랜 발행/폐기, 리비전 발행, 구독 변경, 크레딧 수동 지급/회수, 환산율 변경.
크레딧 수동 조작은 **사유 입력을 필수**로 한다.

---

## 이식하지 않은 것

devkanban 에는 있지만 이 앱에 넣지 않는다. 필요해지면 원본에서 가져온다.

| 항목 | devkanban 원본 |
|---|---|
| 결제 전반 | `order.ex` · `payment*.ex` · `payment_provider/` · webhook · refund · reconciliation |
| 크레딧 팩 구매 | `credit_pack.ex` · `pack_revision.ex` |
| 오토충전 | `auto_recharge_*.ex` |
| 엔터프라이즈 계약 | `enterprise_contract*.ex` |
| 트라이얼 전환 | `trial_conversion_worker.ex` |
| 판매 기간 · 미리보기 | `plan_pricing.ex` · `plan_pricing_policy*.ex` |
| 워크스페이스 런타임 계량 | `workspace_runtime_*.ex` |
| sunset / scheduled change | `sunset_worker.ex` · `scheduled_change_worker.ex` |
