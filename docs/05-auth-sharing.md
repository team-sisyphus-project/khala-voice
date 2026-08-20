# 05. 인증 · 친구 · 공유 · 권한

## 인증 수단

| 수단 | 상태 | 비고 |
|---|---|---|
| 이메일 + 비밀번호 | **항상 활성. 끌 수 없음** | 최후의 로그인 경로 |
| 소셜 로그인 | **어드민에서 제공자별 ON/OFF** | 키가 있고 ON일 때만 노출 |
| MFA (TOTP) | **시스템 어드민은 의무** | 일반 사용자에게는 요구하지 않는다 |

### 어드민 2단계 인증은 의무다

어드민 계정은 TOTP 를 켜야 `/_admin` 에 들어갈 수 있다. 안 켠 상태로 접근하면
설정 화면으로 돌려보낸다 (`MFA.satisfied?/1`).

### 켜는 화면은 어드민 구역 **밖**에 있다

`/login/mfa/enroll` — 로그인 흐름의 일부다. 비밀번호는 통과했고 세션은 아직 없는
상태에서, 등록을 마쳐야 로그인이 끝난다.

어드민 구역 안에 두면 **켜야 들어갈 수 있는 문을 켜기 위해 들어가야 하는** 데드락이
된다. 신규 어드민은 DB 를 직접 건드리지 않는 한 영원히 못 들어간다.
devkanban 이 같은 문제를 같은 방법으로 풀었다 ([14-provenance.md](14-provenance.md)).

| 계정 | 로그인 뒤 어디로 |
|---|---|
| 어드민 · MFA 켬 | `/login/mfa` (코드 확인) |
| 어드민 · MFA 안 켬 | `/login/mfa/enroll` (**등록부터**) |
| 일반 사용자 | 바로 로그인 |

`MFA.verify/2` 는 **켜지 않은 계정을 통과시키지 않는다.** 확인할 수단이 없으면
통과가 아니라 거절이다 — 예전에는 `:ok` 를 돌려줘서, 로그인이 어드민을 무조건
코드 화면으로 보내는 탓에 **MFA 를 안 켠 어드민이 아무 숫자나 넣어도 통과했다.**

어드민 하나가 뚫리면 전체 시스템의 설정 · API 키 · 모든 계정이 함께 넘어간다.
비밀번호 하나로 그것을 지킬 수 없다.

일반 사용자에게는 요구하지 않는다 — 회의록을 보려고 인증기 앱을 깔라고 하면
대부분 떠난다.

> 개발·스테이징에서는 아무 6자리 숫자나 통과한다. 이 우회는 **컴파일 시점에 박혀**
> 운영 빌드에서는 환경변수로도 켤 수 없다.

### 소셜 로그인 ON/OFF

```elixir
# AuthProvider
id              :string
provider        :string    # google | github | kakao | naver | apple | ...
display_name    :string    # 버튼 라벨
client_id       :string
client_secret   VR.Encrypted.Binary   # Cloak 암호화
redirect_uri    :string
scopes          {:array, :string}
enabled         :boolean, default: false
sort_order      :integer
updated_by_id   :string
```

**활성화 판정**

```elixir
def active?(provider) do
  p = get_provider(provider)
  p.enabled and present?(p.client_id) and present?(p.client_secret)
end
```

| 상태 | 로그인 화면 | OAuth 라우트 |
|---|---|---|
| `enabled = true` + 키 있음 | 버튼 노출 | 동작 |
| `enabled = true` + 키 없음 | **노출 안 함** + 어드민에 경고 배지 | 404 |
| `enabled = false` | 노출 안 함 | 404 |

콜백 라우트도 같은 판정을 거친다. 꺼진 제공자로 들어오는 콜백은 거부한다.

**환경변수 폴백**: DB에 값이 없으면 `GOOGLE_OAUTH_CLIENT_ID` 같은 환경변수를 읽는다.
단 `enabled` 스위치는 **DB만** 본다. 환경변수만으로는 켜지지 않는다.
→ [07-config-admin.md](07-config-admin.md)

**끄기 전 안전장치**

소셜로만 가입한 계정이 있는 제공자를 끄면 그 계정들이 로그인 불가가 된다.
어드민 UI는 끄기 전에 다음을 수행한다.

1. 해당 제공자로만 로그인 가능한 계정 수를 표시
2. 0이 아니면 확인 문구 요구
3. 끄기 실행 시 해당 계정들에 비밀번호 설정 안내 메일 발송

### 세션

- `AccountSession`에 기기별 행을 만든다 (토큰 · UA · IP · 마지막 활동 · 만료)
- 설정 화면에서 기기 목록 확인 + 개별/전체 로그아웃
- 비밀번호 변경 시 다른 세션 전체 무효화

### 계정 삭제

즉시 삭제하지 않고 `scheduled_deletion_at`을 세팅한다.
유예 기간 동안 로그인하면 취소할 수 있고, 지나면 `DeletionWorker`가 처리한다.
회의 · 오디오 · 전사본 · 크레딧 원장 처리 정책을 함께 정의한다.

---

## 친구

### 초대 방식

| 방식 | 흐름 |
|---|---|
| **이메일 초대** | 이메일 입력 → 초대 메일 발송 → 링크 클릭 → (미가입이면 가입) → 자동 수락 |
| **링크 초대** | 링크 생성 → 아무 경로로 전달 → 링크 연 사람이 수락 |

```
FriendInvitation
  invited_by_id, email(nil 가능), token, status, expires_at, message
```

**상태 전이**
```
pending ─┬─► accepted    → Friendship 생성
         ├─► declined
         ├─► expired     (expires_at 경과)
         └─► cancelled   (초대자가 취소)
```

### 관계

```
Friendship(account_a_id, account_b_id)   # 항상 정렬된 쌍, 1행
```
- `unique_index(a, b)`로 중복 방지
- 조회는 `where a = me or b = me`
- 차단은 `status = blocked` + `blocked_by_id`

### 친구가 하는 일

친구 목록은 sisyphus의 "프로젝트 멤버" 자리를 대체한다.

- 회의의 Reviewer / Contributor 지정 대상
- 화자 매핑(`speaker_map.account_id`) 대상
- `view_scope = all_friends`일 때의 공개 대상

---

## 권한

### 역할 (명칭 통일)

한국어 UI에서도 이 명칭을 그대로 쓴다. "검토자 / 참여자 / 조회자"로 번역하지 않는다.

| 역할 | 내부 코드 | 권한 |
|---|---|---|
| **Reviewer** | `lv0` | 전권 — 녹음 · 편집 · 삭제 · 아카이브 · 권한 변경 · 공유 링크 발급 |
| **Contributor** | `lv1` | 녹음 · 재생 · 화자/전사 편집 · 요약 생성. 삭제 · 아카이브 · 권한 변경 불가 |
| **Viewer** | `lv2` | 읽기 전용. 오디오 URL 마스킹, 편집 UI 비활성 |
| — | `lv3` | 접근 불가. **404로 응답** (존재 여부도 노출하지 않음) |

### View Scope → 역할 계산

`view_scope`는 사용자가 회의 설정에서 고르는 공개 범위다. 역할은 여기서 자동 계산된다.

| view_scope | 뜻 |
|---|---|
| `me_only` | Reviewer 본인만 |
| `assignees_only` | Reviewer + Contributor만 (기본값) |
| `selected_friends` | 지정한 친구만 (Viewer로) |
| `all_friends` | 내 친구 전체 (Viewer로). **기준은 `reviewer_id` 의 친구 목록이다** — 양도하면 공개 대상이 통째로 바뀐다 |

```elixir
def resolve(meeting, account_id, opts) do
  cond do
    opts[:is_admin]                          -> :lv0   # 시스템 어드민
    account_id == meeting.reviewer_id        -> :lv0   # Reviewer
    account_id in meeting.contributor_ids    -> :lv1   # Contributor
    scope == "me_only"                       -> :lv3
    scope == "assignees_only"                -> :lv3
    scope == "selected_friends" and
      account_id in selected_account_ids     -> :lv2   # Viewer
    scope == "all_friends" and
      friends?(meeting.reviewer_id, account_id) -> :lv2
    true                                     -> :lv3
  end
end
```

> **`me_only` 로 바꿔도 Contributor 는 계속 본다.** 위 `cond` 가 Contributor 검사를
> 공개 범위보다 먼저 하기 때문이다. 사용자는 "비공개로 만들었다" 고 믿으므로
> 화면에서 이 사실을 알리고 "Contributor 모두 해제" 를 함께 제공한다.

저장 형태:
```jsonc
meeting.permissions = {
  "view": { "mode": "selected_friends", "accountIds": ["acct_x", "acct_y"] }
}
```

### 게스트 (공유 링크)

게스트는 계정이 없어도 링크로 접근한다. **기존 권한 체계를 그대로 쓴다** —
게스트에게도 Reviewer/Contributor/Viewer 중 하나가 부여되고, 그 역할의 권한이 그대로 적용된다.

```elixir
SharedLink.granted_role   # "viewer" | "contributor"
```

| 상황 | 결과 |
|---|---|
| 링크 유효 + **그 회의 권한이 있는** 계정 | **계정 권한 우선.** 링크를 쓰지 않는다 — PIN 도 안 묻고 사용 횟수도 안 탄다 |
| 링크 유효 + **권한 없는** 계정 | **익명 방문자와 똑같이 취급한다.** 회의 스위치도 보고 PIN 도 묻는다 |
| 링크 유효 + 비로그인 게스트 | `granted_role` 로 접근. `guest_link_enabled` 가 켜져 있어야 함 |
| PIN 설정됨 | PIN 일치해야 통과. **로그인 여부와 무관하다** |
| PIN 불일치 | 401. 링크별 5회 → 15분 잠금, IP 별 15분 20회 → 잠금 (429) |
| `guest_link_enabled` 꺼짐 | **404** — 링크가 유효했다는 사실도 숨긴다 |
| `max_uses` 소진 / 만료 / 비활성 / 폐기 | 410 Gone. **넷을 구분하지 않는다** |
| 토큰 없음 · 형식 오류 | 404 |

> **"로그인했으면 PIN 면제" 는 권한이 있는 계정에만 해당한다.**
> 권한 없는 계정까지 면제하면 아무나 가입해서 게스트 차단과 PIN 을 동시에 우회한다.
> sisyphus 가 `params["member_id"]` 를 신뢰해 정확히 이 구멍을 갖고 있었다.

**1회성 초대** = `max_uses: 1` + `expires_at` 설정.

### 폐기와 소진은 다르게 동작한다

| | 이미 들어와 있는 게스트 |
|---|---|
| **폐기**(`DELETE`) · **비활성**(`is_active: false`) · **만료** | **즉시 끊긴다** |
| **소진**(`max_uses` 도달) | 그대로 남는다 |

소진은 "더 못 들어온다"는 뜻이지 "들어온 사람을 내보낸다"는 뜻이 아니다.
1회성 링크로 회의록을 받은 사람이 두 번째 요청에서 쫓겨나면 링크가 쓸모없어진다.
폐기는 반대로 지금 보고 있는 사람까지 끊어야 의미가 있다.

**재발급**(`rotate`)은 주소만 바꾼다 — 이미 들어온 게스트는 유지된다.
"링크를 잃어버렸다"와 "쫓아내겠다"는 다른 일이다.

게스트 세션은 별도 토큰으로 관리하며, 해당 회의 하나에만 접근할 수 있다.
게스트가 나중에 계정을 만들어도 그 회의의 권한은 링크가 부여한 범위를 넘지 않는다.

### 권한이 UI에 반영되는 지점

| 항목 | Reviewer | Contributor | Viewer |
|---|---|---|---|
| 제목 · 설명 편집 | ✅ | ✅ | — |
| 녹음 | ✅ | ✅ | — |
| 재생 | ✅ | ✅ | ✅ |
| 화자 · 전사 편집 | ✅ | ✅ | — |
| 요약 생성 · 재요약 | ✅ | ✅ | — |
| 토픽 · 라벨 변경 | ✅ | ✅ | — |
| 공개 범위 변경 | ✅ | — | — |
| 공유 링크 발급 | ✅ | — | — |
| 아카이브 | ✅ | — | — |
| 삭제 | ✅ | — | — |
| 오디오 다운로드 | ✅ | ✅ | 설정에 따름 |
| 마크다운 내보내기 | ✅ | ✅ | ✅ |

**서버가 최종 판정한다.** 프론트의 비활성화는 편의일 뿐이고, 모든 변경 API는
서버에서 역할을 다시 계산해 검증한다.
