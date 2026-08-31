# 07. 설정 · 시크릿 · 시스템 어드민

> **이 리포는 오픈소스로 공개된다.** 어떤 형태의 자격증명도 코드 · 설정 파일 ·
> 시드 · 테스트 픽스처 · 문서에 들어가서는 안 된다.

## 설정 해석 순서

모든 외부 자격증명과 운영 설정은 **단 하나의 경로**로만 읽는다.

```elixir
VR.Config.fetch(:storage, :access_key_id)

#  1) DB           system_configs / auth_providers / llm_providers   (Cloak 암호화)
#  2) 환경변수      System.get_env("STORAGE_ACCESS_KEY_ID")
#  3) nil          → 해당 기능 비활성 + 어드민에 "미설정" 표시
```

**규칙**

| # | 규칙 |
|---|---|
| R1 | 코드에 리터럴 기본값을 두지 않는다. 값이 없으면 없는 대로 기능이 꺼진다 |
| R2 | 값을 읽는 코드는 `VR.Config` 한 곳뿐이다. 각 모듈이 `System.get_env`를 직접 부르지 않는다 |
| R3 | 비밀값은 로그 · 에러 메시지 · API 응답에 절대 나타나지 않는다 (`redact`) |
| R4 | 어드민 UI는 저장된 비밀값을 되돌려 보여주지 않는다. 마스킹 + "설정됨/미설정"만 표시 |
| R5 | `CLOAK_KEY`가 없으면 **부팅 실패**. 기본 키를 만들지 않는다 |

> **R1 · R2 의 적용 범위 — 부팅 파라미터는 예외다.**
> 두 규칙은 `VR.Config`가 다루는 **자격증명**에 대한 것이다.
> `PORT` · `HTTPS_PORT` · `POOL_SIZE` 처럼 Repo 가 뜨기 전에 필요한
> 부팅 파라미터는 DB 를 읽을 수 없으므로 `config/runtime.exs` 에서
> `System.get_env` 로 직접 읽고 리터럴 기본값을 갖는다.
> 이들은 비밀값이 아니고, 없다고 해서 꺼야 할 기능도 없다.
> 새 항목을 이 예외에 넣으려면 "Repo 이전에 필요한가"를 먼저 답해야 한다.
> 자격증명이면 답은 항상 `VR.Config.Registry` 다.

## 시크릿 사고 방지

| 장치 | 내용 |
|---|---|
| `.env.example` | 키 이름만 나열, 값은 전부 빈 문자열 |
| `.gitignore` | `.env*`(단 `.env.example` 제외), `*.pem`, `*credentials*.json` |
| pre-commit 훅 | `gitleaks protect --staged` — 커밋 자체를 막는다 |
| CI | `gitleaks detect` 전체 히스토리 스캔. 발견 시 빌드 실패 |
| 시드 | 더미 값만. 실제 키가 들어간 시드를 만들지 않는다 |
| PR 템플릿 | "시크릿을 추가하지 않았다" 체크박스 |

> **참고 (실제 사고 사례)**: sisyphus 리포의 `n8n-workflows/*.json` 3개 파일에
> AWS 액세스 키/시크릿이 평문으로 커밋되어 있었다. 이런 유형(설정 JSON, 워크플로 export,
> 노트북, 스크린샷)이 가장 흔한 유출 경로다. gitleaks 규칙에 `*.json` export 파일을 포함시킨다.

## 암호화

```elixir
VR.Vault              # Cloak.Vault, AES-256-GCM, 키는 CLOAK_KEY (base64 32바이트)
VR.Encrypted.Binary   # Ecto 타입. 저장 시 암호화, 로드 시 복호화

field :client_secret, VR.Encrypted.Binary, source: :client_secret_encrypted
```
키 생성: `openssl rand -base64 32`

---

## 설정 스키마

### SystemConfig — 범용 key-value
```elixir
id, key, value, encrypted :boolean, description, updated_by_id
```

| 그룹 | 키 | 암호화 |
|---|---|---|
| **스토리지** | `storage.provider` (`s3`) | |
| | `storage.bucket`, `storage.region` | |
| | `storage.access_key_id` | ✅ |
| | `storage.secret_access_key` | ✅ |
| | `storage.cdn_base_url` | |
| | `storage.download_url_ttl_seconds` | |
| **Google STT** | `stt.credentials_json` (서비스 계정 JSON) | ✅ |
| | `stt.project_id`, `stt.location`, `stt.recognizer` | |
| | `stt.gcs_bucket` (batchRecognize 임시 버킷) | |
| | `stt.dev_mode` (목 응답) | |
| **메일** | `mail.provider`, `mail.domain` | |
| | `mail.api_key` | ✅ |
| **푸시** | `push.vapid_public_key` | |
| | `push.vapid_private_key` | ✅ |
| | `push.vapid_subject` | |
| **정책** | `policy.invite_code_required` | |
| | `policy.hard_stop_on_zero_credits` (기본 false) | |
| **앱** | `app.base_url` | |
| | `app.timezone` (기본 `Asia/Seoul`) | |
| | `app.trust_proxy_headers` (기본 false) | |
| **AI 요약** | `llm.dev_mode` | |
| | `llm.auto_summarize` | |
| **어드민 접근** | `admin.username` | |
| | `admin.password` | ✅ |

> **어드민 접근 (M0 임시)**: 계정 체계가 아직 없어 HTTP Basic 인증을 쓴다.
> dev에서는 자격증명이 없으면 통과하고, **prod에서는 없으면 503으로 막는다**
> — 설정 누락이 곧 어드민 전체 공개가 되는 상황을 만들지 않는다.
> M1에서 `Account.is_admin` 기반으로 교체하며 이 항목은 삭제된다.

### AuthProvider — 소셜 로그인
```elixir
id, provider, display_name,
client_id, client_secret(암호화), redirect_uri, scopes,
enabled :boolean, sort_order, updated_by_id
```
활성화 판정과 안전장치는 [05-auth-sharing.md](05-auth-sharing.md#소셜-로그인-onoff) 참조.

### LlmProvider — 요약용 LLM
```elixir
id, provider,          # gemini | anthropic | openai
   display_name,
   api_key(암호화),
   base_url,           # 프록시/호환 엔드포인트용 (선택)
   model,              # 실제 모델 ID
   tier,               # ModelPricing 조인 키 (high|mid|low)
   temperature,        # 기본 0.2
   max_output_tokens,  # 기본 16384
   enabled :boolean,
   priority :integer   # 낮을수록 우선. 실패 시 다음 제공자로 폴백
```

**선택 로직**
```
enabled = true 이고 api_key 있는 것 중 priority 오름차순 → 첫 번째 사용
호출 실패(레이트리밋·5xx) → 다음 우선순위로 폴백
전부 실패 → summary_failed, last_summary_error 기록
```

### CommerceSettings — 대외 명칭
```elixir
credit_term :map, plan_term :map, locale_overrides :map
```

---

## 환경변수

`.env.example`에 이름만 둔다. DB 미설정 시 폴백으로만 쓰인다.

```bash
# ── 필수 (앱) ───────────────────────────────
DATABASE_URL=
SECRET_KEY_BASE=
CLOAK_KEY=                    # openssl rand -base64 32
PHX_HOST=
PORT=                          # 선택 — 비우면 4000
APP_BASE_URL=

# ── 스토리지 (S3) ──────────────────────────
STORAGE_BUCKET=
STORAGE_REGION=
STORAGE_ACCESS_KEY_ID=
STORAGE_SECRET_ACCESS_KEY=
STORAGE_CDN_BASE_URL=

# ── Google Cloud STT ───────────────────────
STT_CREDENTIALS_JSON=
STT_PROJECT_ID=
STT_LOCATION=
STT_RECOGNIZER=
STT_GCS_BUCKET=
STT_DEV_MODE=

# ── LLM (요약) ─────────────────────────────
LLM_PROVIDER=
LLM_API_KEY=
LLM_MODEL=

# ── 소셜 로그인 (선택) ─────────────────────
GOOGLE_OAUTH_CLIENT_ID=
GOOGLE_OAUTH_CLIENT_SECRET=
GOOGLE_OAUTH_REDIRECT_URI=
GITHUB_OAUTH_CLIENT_ID=
GITHUB_OAUTH_CLIENT_SECRET=
GITHUB_OAUTH_REDIRECT_URI=

# ── 메일 · 푸시 ────────────────────────────
MAIL_PROVIDER=
MAIL_DOMAIN=
MAIL_API_KEY=
VAPID_PUBLIC_KEY=
VAPID_PRIVATE_KEY=
VAPID_SUBJECT=
```

> **소셜 로그인의 `enabled`는 환경변수로 켜지지 않는다.** 키만 환경변수로 주고
> 켜는 것은 어드민에서 한다. 실수로 배포 환경에서 로그인 수단이 바뀌는 것을 막기 위함이다.

---

## 시스템 어드민 (`/_admin`)

Phoenix LiveView. `Account.is_admin = true`만 접근.

| 그룹 | 화면 | 내용 |
|---|---|---|
| **설정** | 스토리지 | S3 버킷 · 리전 · 키 · CDN. [연결 테스트] 버튼 |
| | 전사(STT) | GCP 자격증명 · 프로젝트 · 리전 · recognizer · GCS 버킷 · 개발모드 |
| | LLM | 제공자 목록 CRUD. 키 · 모델 · 우선순위 · ON/OFF. [테스트 호출] |
| | 소셜 로그인 | 제공자별 키 + ON/OFF. 끄기 전 영향 계정 수 경고 |
| | 메일 · 푸시 | 발송 설정 |
| | 정책 | 가입 초대코드 필수 여부, 크레딧 하드스톱 스위치 |
| **가격** | ServicePricing | STT 등 외부 API 단가 → 크레딧 환산율 |
| | ModelPricing | LLM 모델별 단가 → 크레딧 환산율 |
| **상거래** | 플랜 | Plan CRUD, 리비전 발행 이력, 메타/상업 편집 분리 |
| | 구독 | 계정별 구독 조회 · 플랜 변경 |
| | 크레딧 | 잔액 조회, 수동 지급/회수(사유 필수), 원장 타임라인 |
| | 용어 | 크레딧 대외 명칭 + 미리보기 |
| | 감사 로그 | BillingAuditLog 조회 |
| **운영** | 계정 | 검색 · 상태 · 세션 · 삭제 예약 |
| | 회의 | 검색 · 상태 · 세션 상태 · 실패 건 재시도 |
| | 잡 | Oban 큐 상태 · 실패 잡 · 재시도 |
| | 로그 | 전사/요약 실패 로그 |

### 어드민 UI 규칙

1. 비밀값 필드는 **저장된 값을 되돌려 보여주지 않는다.** `••••••••` + "설정됨(2026-08-19 갱신)" 표시
2. 저장 시 빈 값이면 **기존 값 유지** (실수로 지우는 것 방지). 삭제는 별도 [지우기] 버튼
3. 외부 연동 설정에는 **[연결 테스트]** 를 둔다. 저장 전에 유효성을 확인할 수 있어야 한다
4. 어드민의 모든 설정 변경은 `updated_by_id`와 함께 감사 로그에 남긴다
5. 미설정 항목은 대시보드 상단에 **경고 배너**로 모아 보여준다
   (예: "LLM 제공자가 설정되지 않아 AI 요약이 비활성 상태입니다")
