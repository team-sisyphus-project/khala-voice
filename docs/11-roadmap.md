# 11. 로드맵

각 마일스톤은 독립적으로 배포 가능하고 검증 가능해야 한다.

## M0 — 기반  ✅ 완료

| 항목 | 산출물 |
|---|---|
| 리포 구조 | `backend/`, `packages/core/`, `apps/web/` |
| Phoenix 앱 | 부팅, Repo, Oban, Cloak(`CLOAK_KEY` 없으면 부팅 실패) |
| 설정 계층 | `VR.Config` (DB → ENV → nil), `SystemConfig` 스키마 |
| 시크릿 방어 | `.gitignore`, `.env.example`, gitleaks pre-commit + CI |
| CI | 컴파일 · 포맷 · 테스트 · 시크릿 스캔 |
| 컨테이너 | **FFmpeg 포함** Dockerfile |

**완료 기준**: 빈 앱이 뜨고, 시크릿이 커밋되지 않으며, `ffmpeg -version`이 컨테이너에서 동작한다.

**실제 구현된 것** (계획보다 앞당김 — 배포 후 DB로 키를 넣을 수 있어야 하므로
어드민 설정 화면을 M0에 포함했다):

- `VR.Config` — DB → 환경변수 → nil 3단 해석, 리터럴 기본값 없음
- `VR.Config.Registry` — 설정 키 선언. **어드민 화면이 여기서 생성된다**
- `VR.Vault` / `VR.Encrypted.Binary` — Cloak AES-256-GCM. `CLOAK_KEY` 없으면 부팅 실패
- `SystemConfig` / `AuthProvider` / `LlmProvider` 스키마 + 마이그레이션
- 어드민 LiveView — 대시보드 · 설정(그룹별) · 소셜 로그인 · LLM 제공자
- Oban(4개 큐) · ExAws · Dockerfile(FFmpeg+UTF-8 로케일) · CI(gitleaks 포함) · pre-commit 훅
- 테스트 27개 통과

## M1 — 계정 · 친구  ✅ 완료

| 항목 |
|---|
| Account · AccountSession · AccountToken · LoginAttempt |
| 이메일 가입 · 로그인 · 확인 메일 · 비밀번호 재설정 |
| `AuthProvider` + 소셜 로그인 ON/OFF (어드민 UI 포함) |
| 기기 세션 목록 · 원격 로그아웃 |
| FriendInvitation · Friendship, 이메일/링크 초대 |
| 계정 삭제 예약 + `DeletionWorker` |

**완료 기준**: 소셜 제공자를 어드민에서 켜고 끄면 로그인 화면과 OAuth 라우트가 함께 반응한다.
키 없이 켜면 노출되지 않는다.

**진행 상황**

- [x] `VR.IdGenerator` — 접두사 ID (`acct_…`, `frnd_…`, `finv_…`)
- [x] `Account` · `AccountSession` · `AccountToken` · `LoginAttempt` 스키마 + 마이그레이션
- [x] `VR.Accounts` — 가입 · 로그인 · 세션 · 이메일 토큰 · 시도 제한 · 삭제 예약 · 소셜 연결
- [x] `Friendship` · `FriendInvitation` 스키마 + 마이그레이션
- [x] `VR.Friends` — 친구 목록 · 초대 생성/수락/거절/취소 · 차단
- [x] 테스트 81개
- [x] 디자인 시스템 이식 — sisyphus 토큰 + `.vr-*` 컴포넌트 ([12-design-system.md](12-design-system.md))
- [x] 웹 레이어 — 로그인 · 가입 · 비밀번호 재설정 · 이메일 확인
- [x] `VRWeb.UserAuth` — 세션 쿠키(http_only · SameSite=Lax · 서명), 세션 고정 방어
- [x] 초대 코드 정책 (`policy.invite_code_required`) + 트랜잭션 소진
- [x] OAuth 실제 흐름 — Google · GitHub, state CSRF 방어, 꺼진 제공자는 404
- [x] 메일 발송 (확인 · 재설정 · 친구 초대)
- [x] 어드민 인증을 `Account.is_admin` 으로 교체 + `mix vr.make_admin`
- [x] 테스트 96개
- [x] 친구 화면 — 이메일/링크 초대, 보낸 초대 관리, 수락 화면
- [x] 계정 설정 화면 — 프로필 · 비밀번호 · 기기 세션 · 삭제 예약
- [x] `DeletionWorker` (매시) · `InvitationCleanupWorker` (매일)

## M2 — 녹음 · 업로드 (핵심)  🔨 진행 중

| 항목 |
|---|
| Meeting · RecordingSession 스키마 + API |
| `packages/core/recorder` — MediaRecorder · 파형 · 타이머 · **통일된 일시정지** |
| `packages/core/upload` — IndexedDB 큐 · 재시도 · 실패 배너 |
| `VR.Storage.S3` presign (ExAws) |
| `apps/web` 최소 UI — 목록 · 상세 · 녹음 |
| SSE 기본 배선 |

**완료 기준**: 녹음 → S3 업로드 → 세션 등록이 끝까지 동작하고,
**비행기 모드에서 녹음한 것이 온라인 복귀 후 자동 업로드된다.**

**진행 상황**

- [x] `Meeting` · `RecordingSession` 스키마 + 마이그레이션 (pg_trgm 검색 인덱스 포함)
- [x] `VR.Access.AccessLevel` — Reviewer / Contributor / Viewer, 게스트 역할
- [x] `VR.Meetings` — 권한 기반 조회, 필터 목록, 세션 관리, 전사 검증
- [x] `VR.Storage` + S3 presign (ExAws SigV4, n8n 제거)
- [x] REST API 12개 엔드포인트 + Viewer 마스킹
- [x] 테스트 137개
- [x] `packages/core/recorder` — MediaRecorder 엔진 · 파형 · **통일된 일시정지** · 중단 감지
- [x] `packages/core/upload` — IndexedDB 큐 · 순차 업로드 · 재시도 · 진행률
- [x] `packages/core/api` — 타입 있는 API 클라이언트
- [x] 실기기 스파이크 페이지 `/spike/recorder` + HTTPS 개발 설정
- [ ] **모바일 실기기 백그라운드 녹음 검증** ← 최우선 리스크 · [절차](13-device-testing.md)
- [x] `apps/web` React SPA (Vite) — Phoenix 가 `/app` 에서 서빙
- [x] `useRecorder` 훅 — 엔진을 React 에 연결 (파형은 캔버스 직접 그리기)
- [x] 회의 목록 · 상세 · 녹음 · 세션 목록 · 아카이브 검색
- [x] 테마 4종 (라이트 · 다크 · 연필 · 게임) — 사용자별 설정 · 지연 로드
- [x] 반응형 — 하단 탭바(모바일) / 상단 네비(데스크톱), 같은 라우트
- [x] 시스템 어드민 계정 관리 — 승격 · 강등 · 삭제 + **잠금 방지**
- [x] 부트스트랩 어드민 (`mix vr.bootstrap_admin`) — 실사용자 승격 후 삭제해 입구를 닫는다
- [x] 어드민 전용 MFA (TOTP) — 운영 외 환경은 6자리 숫자 우회
- [ ] 어드민 계정 관리 화면 (`/_admin/accounts`)
- [ ] MFA 설정 화면
- [ ] 토픽 · 라벨 CRUD + 아카이브 필터 UI
- [ ] SSE 연결 (지금은 폴링)

## M3 — 전사 · 화자  ✅ 완료

| 항목 |
|---|
| `GoogleSTT` 이식 + `VR.Config` 연결 + 개발 모드(목 응답) |
| `AudioSplitter` + `AudioSplitWorker` (20분 초과 분할) |
| `TranscriptionWorker` |
| 전사 뷰 (채팅 스타일) · 통합 오디오 플레이어 · 세그먼트 하이라이트 |
| 화자 편집 — 칩 변경 · 세그먼트 변경 · 추가/삭제 · 텍스트 편집 · 분할 · 원본 복원 · 재전사 |

**완료 기준**: 30분 이상 녹음이 분할 → 전사 → 화자 매핑까지 도달하고,
GCP 자격증명 없이도 개발 모드로 전체 UI를 확인할 수 있다.

**진행 상황** — 전부 sisyphus 이식 ([14-provenance.md](14-provenance.md#전사-파이프라인-m3-예정))

- [x] `VR.Transcription.GoogleSTT` — batchRecognize · GCS 왕복 · 5초 폴링 · 임시파일 정리
- [x] `VR.Transcription.Audio` — ffprobe 길이 · 19분 분할 · MP3 변환 (**FFmpeg 실측 확인**)
- [x] `TranscriptionWorker` — 변환 → STT → 저장 → **크레딧 계량** → 집계
- [x] `AudioSplitWorker` — 20분 초과 분할 → 청크 세션 생성 → 원본 삭제 → 재큐잉
- [x] 개발 모드 — GCP 키 없이 목 전사 (5세그먼트 · 3화자)
- [x] `POST /api/sessions/:id/transcribe` + React 전사 버튼
- [x] `packages/core/domain/transcript` — 화자·세그먼트 조작 로직 (UI 프레임워크 없음)
- [x] 전사 뷰 (채팅 스타일) · 통합 오디오 플레이어 · 재생 중 세그먼트 하이라이트
- [x] 화자 편집 — 이름 · 친구 연결 · 추가/삭제 · 세그먼트 화자 변경 · 텍스트 편집 · 분할 · 원본 복원
- [x] `PATCH /api/sessions/:id/speakers` · `GET /api/friends`
- [x] 테스트 — 백엔드 240개 + core 26개 (`node --test`)

**M3 완료.** 30분 초과 녹음이 분할→전사→화자 매핑까지 도달하고,
GCP 자격증명 없이 개발 모드로 전체 UI를 확인할 수 있다.

## M4 — AI 요약  ✅ 완료

| 항목 |
|---|
| `LLM.Client` + Gemini / Anthropic / OpenAI 어댑터 |
| `LlmProvider` 어드민 (키 · 모델 · 우선순위 · 폴백) |
| 프롬프트 파일 + 직렬화 · 스키마 검증 · 정규화 |
| `SummaryWorker` (auto / retry) |
| 요약 뷰 + **출처 클릭 → 오디오 점프** |

**완료 기준**: 요약 항목을 클릭하면 해당 발언 지점이 재생된다.
제공자를 어드민에서 바꿔도 출력 스키마가 동일하다.

**진행 상황**

- [x] `VR.Summarize.Serializer` — `[session_id|speaker|HH:MM:SS] 발화` 직렬화 (sisyphus 규약)
- [x] `VR.Summarize.Prompt` — 시스템 프롬프트 + JSON 스키마 (sisyphus n8n 프롬프트 이식)
- [x] `VR.Summarize.Normalizer` — 정규화 + **`source` 를 실제 전사와 대조해 날조 차단**
- [x] `VR.Summarize.LLM` + Gemini / Anthropic / OpenAI 어댑터 · 재시도 가치 있는 실패만 폴백
- [x] `SummaryWorker` — `meeting_id` unique · auto 가드 · retry 강제
- [x] 개발 모드 — 키 없이 목 요약. **실제 전사에서 인용을 뽑아 점프까지 확인 가능**
- [x] 토큰 계량 — devkanban `price_tokens/3` 계산식 이식 (단가 없으면 계량 생략)
- [x] 어드민 — 제공자 CRUD · 단가 · 개발 모드 / 자동 요약 스위치
- [x] `POST /api/meetings/:id/summarize`
- [x] 요약 뷰 — 근거 칩 클릭 → 그 지점 재생 · 원문 펼치기
- [x] 테스트 35개 추가 (직렬화 12 · 정규화 15 · 계량/폴백 8)

**부수 수확** — 오버드래프트 상태에서 워커 재시도가 **같은 사용을 여러 번 차감하던 버그**를
계량을 붙이다 발견해 고쳤다. 무료 플랜은 잔액 0 이 기본 상태라 이 경로가 정상 경로다.
→ [06-billing.md](06-billing.md#멱등성)

## M5 — 공유 · 권한 · 분류  ✅ 완료

| 항목 |
|---|
| `Access.AccessLevel` — Reviewer / Contributor / Viewer |
| 공개 범위 설정 UI (`me_only` / `assignees_only` / `selected_friends` / `all_friends`) |
| `SharedLink` + `granted_role` + PIN + 1회성 |
| 게스트 뷰 `/share/:token` |
| Topic · Label CRUD |
| **아카이브 필터 검색** (토픽 · 라벨 · 기간 · 참여자 · 전문검색) |
| 마크다운 내보내기 |

**완료 기준**: 1회성 링크를 발급해 비로그인 상태에서 열면 지정한 역할로만 접근된다.
아카이브된 회의를 토픽/라벨로 찾을 수 있다.

**진행 상황**

- [x] **보안 하드닝** (게스트 링크의 선행 — 자세한 내용은 [10-porting-map.md](10-porting-map.md) B8~B10)
  - [x] 클라이언트가 준 `audio_url` 을 받지 않는다. presign 이 키를 정해 `storage_key` 에 기록
  - [x] 워커 SSRF 가드 — `Storage.own_object_url?/1` 통과 + `max_redirects: 0`
  - [x] `audio_href` → `GET /api/sessions/:id/audio` → presigned GET 302 (Viewer 는 404)
  - [x] 아카이브 잠금 — 업로드 · presign · 전사 · 전사본 수정
- [x] **Topic · Label CRUD** — 스키마 · 컨텍스트 · REST · 소프트 삭제 + detach · 정렬 · 소유권 검증
- [x] **목록 쿼리 하드닝** — `count_meetings/2` · 라벨 배열 타입 명시 · LIKE 이스케이프 · 참여자 필터 · offset
- [x] **아카이브 필터 검색 UI** — 토픽 · 라벨(AND/OR) · 기간 · 참여자 · 전문검색 · **URL 쿼리 동기화**
- [x] 분류 관리 화면 (`/app/taxonomy`)
- [x] **`SharedLink`** — 토큰 sha256 해시 · PIN Bcrypt · `granted_role` · 1회성 · 만료 · 재발급
- [x] **`GuestSession`** (신규) — 회의 하나에만 묶인다. 폐기·비활성·만료가 즉시 끊는다
- [x] **게스트 공개 API** — 경로에 회의 id 가 없다. 전사·요약·업로드 라우트를 두지 않았다
- [x] 게스트 뷰 `/share/:token` + Reviewer 공유 다이얼로그
- [x] 마크다운 내보내기 (`GET /api/meetings/:id/export.md`)
- [x] **적대적 검증** — 5개 렌즈로 44건 지적 → 반증 후 실제 결함만 수정 (아래)
- [x] **공개 범위 설정 UI** — 4개 범위 · 친구 지정 · Contributor 지정 · **Reviewer 양도**
- [x] **"나만" 함정 경고** — 서버는 Contributor 검사를 공개 범위보다 먼저 하므로 "나만" 으로 바꿔도 Contributor 는 계속 본다. 사용자는 비공개로 만들었다고 믿는다

**적대적 검증에서 고친 것**

| 문제 | 고침 |
|---|---|
| 공유 토큰이 URL 경로라 Phoenix 요청 로그에 **평문으로** 남았다 | `VR.LogRedactor` — 로거 앞단에서 `slt_`/`gst_` 를 가린다 |
| PIN 5회 잠금이 read-modify-write 라 동시 요청에 무너졌다 | 증가와 잠금을 **한 UPDATE 문**으로 |
| 로그인만 하면 `guest_link_enabled` 차단을 우회하고 1회성 링크를 태울 수 있었다 | 스위치는 로그인 여부와 무관. 권한 없는 계정은 익명과 동일 취급 |
| 계정 진입 경로가 요청 본문을 버려 PIN·이름이 전달되지 않았다 (로그인한 제3자가 5번 두드려 링크를 15분 잠글 수 있었다) | `params` 를 그대로 전달 |
| `is_active: false` 와 만료 단축이 이미 들어온 게스트를 못 끊었다 | `fetch_live_guest` 가 링크 상태를 매 요청 재확인 (소진은 예외 — 문서화된 정책) |
| `speaker_map[].account_id` 가 게스트에게 나갔다 | 이름만 남기고 계정 id 제거 |
| `X-Forwarded-For` 를 무조건 믿어 IP 잠금이 무력했다 | `app.trust_proxy_headers` 로 명시적으로 켤 때만 |
| gitleaks 첫 allowlist 에 `targetRules` 가 없어 `docs/` 아래 **모든 규칙이 꺼져** 있었다 | 범용 규칙에만 적용. `slt_`/`gst_` 탐지 규칙 추가 |

## M6 — 구독 · 크레딧  ✅ 완료

| 항목 |
|---|
| Plan · PlanRevision · Subscription |
| CreditLot · CreditLedgerEntry (FIFO · append-only) |
| ServicePricing · ModelPricing + 전사/요약 사용량 기록 |
| MonthlyGrantWorker · CreditExpiryWorker |
| 어드민 — 플랜 · 크레딧 지급/회수 · 원장 · 감사 로그 |
| 사용자 화면 — 잔액 · 사용 내역 |
| Free 플랜 자동 구독 |

**완료 기준**: 전사 1건 후 원장에 정확한 크레딧과 원가가 기록된다.
잔액이 음수여도 서비스는 계속 동작한다.

**진행 상황** — 전부 devkanban 이식 ([14-provenance.md](14-provenance.md#요금-정책--06-billingmd))

- [x] `Plan` · `PlanRevision` — 메타/상업 조건 분리, 리비전 핀 고정으로 그랜드파더링
- [x] `Subscription` — 계정당 1개, 기간 관리
- [x] `CreditLot` · `CreditLedgerEntry` — append-only, `Σ delta == Σ remaining`
- [x] **FIFO 소비** — 만료 임박 → 무기한 → 삽입순, `FOR UPDATE` 잠금
- [x] **오버드래프트** — 사후 계량은 잔액이 모자라도 기록한다
- [x] `CreditConversionSetting` — 싱글턴 USD→크레딧, 올림
- [x] `MonthlyGrantWorker` · `CreditExpiryWorker`
- [x] 가입 시 무료 플랜 자동 구독 + 첫 기간 크레딧 지급
- [x] 어드민 요금 화면 (`/_admin/billing`) — 환산율 · 리비전 발행
- [x] 테마 4종 · 어드민 계정 관리 · MFA (앞선 작업)
- [x] 테스트 223개
- [x] 사용자 요금 화면 (`/app/billing`) — 잔액 · 남은 묶음 · **사용 내역 + 계산 근거**
- [x] 전사·요약 워커에서 `charge_usage` 호출 (M3/M4 에서 연결됨)

## M7 — PWA · 마감  🔨 진행 중

| 항목 |
|---|
| manifest · 서비스 워커 · 설치 프롬프트 |
| 푸시 알림 (전사/요약 완료) |
| i18n 6개 언어 정리 |
| 접근성 (`aria-live`, 색상 외 구분) |
| **실기기 검증** — iOS Safari / Android Chrome 백그라운드 녹음 |
| 오픈소스 준비 — README · LICENSE · CONTRIBUTING · 시크릿 최종 스캔 |

**진행 상황**

- [x] **PWA** — manifest · 아이콘(192/512/maskable/apple-touch) · 서비스 워커 · 설치 배너
- [x] **푸시 알림** — VAPID 구독 · 전사/요약 완료 시 발송 · 기기별 구독 관리
- [x] 기기 설정 화면 (`/app/settings`) — 알림 · 홈 화면 추가 안내
- [x] 접근성 — 녹음 상태 `aria-live` 안내 · 색상 외 구분(체크·굵기) · 화자 이름 병기
- [x] 오픈소스 준비 — README 기능표 · CONTRIBUTING · SECURITY · 시크릿 스캔 0건
- [ ] **LICENSE** — 라이선스 선택은 프로젝트 소유자의 결정이라 비워 둠
- [ ] i18n 6개 언어 (아래)
- [ ] 실기기 검증 (지금은 불가)

### 서비스 워커에서 조심한 것

녹음 앱이라 잘못 캐시하면 회의가 날아간다. 범위를 좁게 잡았다.

| 규칙 | 왜 |
|---|---|
| `/api/` 는 **절대** 가로채지 않는다 | 인증 걸린 응답을 캐시하면 로그아웃 뒤에도 남의 회의록이 보인다 |
| GET 이 아니면 손대지 않는다 | S3 presigned PUT 이 서비스 워커를 거치면 서명이 어긋난다 |
| 해시 붙은 자산만 캐시 우선 | 이름이 같은데 내용이 바뀌는 파일을 캐시하면 사용자가 옛 코드에 갇힌다 |
| 셸은 네트워크 우선 | 새 배포를 즉시 받는다. 오프라인일 때만 캐시로 떨어진다 |

### i18n 이 남은 이유

문자열이 **488개 / 31개 파일**이다. 기계적으로 옮기는 것은 가능하지만
ja · es · zh_CN · zh_TW 번역은 원어민 검토 없이는 제품에 넣을 품질이 안 된다.
절반만 키로 바꾸면 sisyphus 가 비판받던 "하드코딩과 키가 섞인" 상태가 되므로,
**한 번에 끝내는 별도 작업**으로 둔다.

인프라 준비는 돼 있다 — 계정에 `locale` 필드(6개 언어)가 있고
`packages/core` 가 프레임워크 비의존이라 번역 계층을 넣을 자리가 있다.

---

## 리스크

| # | 리스크 | 영향 | 대응 |
|---|---|---|---|
| R1 | **모바일 백그라운드에서 녹음 중단** | 긴 회의 유실 | M2에서 조기 실기기 테스트. 화면 꺼짐 방지(Wake Lock), 주기적 부분 저장, 중단 감지 시 즉시 세션 마감 |
| R2 | iOS Safari의 MediaRecorder 제약 | 포맷·동작 차이 | mp4/aac 폴백 유지. 초기부터 실기기 검증 |
| R3 | STT 폴링 30분 초과 | 긴 오디오 실패 | 분할 임계값(20분) 준수, 폴링 상한 조정 가능하게 |
| R4 | FFmpeg 미설치 | 20분 초과 전사 전부 실패 | 부팅 시 바이너리 존재 확인 + 어드민 경고 배너 |
| R5 | LLM 출력 스키마 위반 | 요약 파싱 실패 | 구조화 출력 강제 + 검증 실패 시 1회 재시도 후 `summary_failed` |
| R6 | 화자분리 정확도 | 사용자 수동 교정 부담 | 세그먼트 단위 교정 UI가 핵심 완화책. 단축키 제공 |
| R7 | 한국어 전문검색 품질 | 아카이브 검색 부실 | `pg_bigm`/trigram 우선 검증. 부족하면 별도 인덱싱 검토 |
| R8 | 크레딧 원장 중복 기록 | 집계 오류 | `idempotency_key` unique 제약. 워커 재시도 안전성 테스트 |

---

## 검증 우선순위

기능이 아니라 **불확실성**이 큰 것부터 확인한다.

1. **M2에서 모바일 실기기 녹음** — 여기서 막히면 제품 전제가 흔들린다 (R1, R2)
2. **M3에서 20분 초과 분할 전사** — 파이프라인에서 가장 복잡한 경로 (R3, R4)
3. **M4에서 요약 출처 점프** — 핵심 UX가 실제로 성립하는지 (R5)
4. 나머지는 이식 위주라 상대적으로 예측 가능하다
