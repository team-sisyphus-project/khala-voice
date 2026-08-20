# 10. 이식 대조표

> 파일 단위 대조표다. **무엇이 어디서 왔는지 전체 그림**은
> [14-provenance.md](14-provenance.md) 를 본다.

무엇을 어디서 가져오고, 무엇을 새로 만들고, 무엇을 버리는가.

## sisyphus → voice-recording

### 백엔드

| sisyphus | 신규 | 변경 |
|---|---|---|
| `lib/sisyphus/meetings/meeting.ex` | `vr/meetings/meeting.ex` | `project_id` 제거, `meeting_type` 제거, 레거시 필드 제거, `member_id`→`account_id` |
| `lib/sisyphus/meetings/recording_session.ex` | `vr/meetings/recording_session.ex` | 거의 그대로 |
| `lib/sisyphus/meetings.ex` | `vr/meetings.ex` | 아카이브/벡터DB/화상 관련 제거 |
| `lib/sisyphus/meetings/google_stt.ex` (997줄) | `vr/transcription/google_stt.ex` | **거의 그대로.** 설정 소스만 `VR.Config`로 |
| `lib/sisyphus/meetings/audio_splitter.ex` | `vr/transcription/audio_splitter.ex` | 그대로 |
| `workers/meeting_transcription_worker.ex` | `vr/workers/transcription_worker.ex` | 과금 호출부만 교체 |
| `workers/audio_split_worker.ex` | `vr/workers/audio_split_worker.ex` | 업로드 경로만 교체 |
| `workers/meeting_summary_worker.ex` | `vr/workers/summary_worker.ex` | **n8n 호출 → LLM 직접 호출로 교체** |
| `lib/sisyphus/access/access_level.ex` | `vr/access/access_level.ex` | `project_members`→`all_friends`, 조직 개념 제거 |
| `lib/sisyphus/shared_links/*` | `vr/sharing/*` | `granted_role` 추가, 화상 관련 제거 |
| `lib/sisyphus/accounts/*` | `vr/accounts/*` | MFA · PasswordHistory · EmailHashHistory 제거 |
| `lib/sisyphus/system/system_config*.ex` | `vr/config/*` | 키 목록 확장 |
| `lib/sisyphus/vault.ex` + `encrypted/binary.ex` | `vr/vault.ex` | 그대로 |
| `lib/sisyphus/billing/service_pricing.ex` | `vr/billing/service_pricing.ex` | 그대로 |
| `lib/sisyphus/billing/model_pricing.ex` | `vr/billing/model_pricing.ex` | 그대로 |
| `controllers/meeting_controller.ex` | `vr_web/controllers/meeting_controller.ex` | 조직/프로젝트 권한 체크 → 친구/공유 체크 |
| `live/admin/billing_service_pricing_live.ex` | `vr_web/live/admin/...` | 그대로 |
| `live/admin/billing_model_pricing_live.ex` | `vr_web/live/admin/...` | 그대로 |
| `lib/sisyphus/organizations/invitation.ex` | `vr/friends/friend_invitation.ex` | 역할 필드 제거, 친구 초대로 전환 |
| `n8n_upload/upload_url_v2.ex` | `vr/storage/s3.ex` | **n8n 웹훅 → ExAws presign 직접 구현** |

**버림**: 조직 · 프로젝트 · 태스크 · 저스트챗 · 커뮤니케이션(CRM) · 다이제스트 ·
아카이브(벡터DB) · 인박스/멘션 · 에이전트/MCP · Agora 화상회의 전체 ·
결제(LemonSqueezy/Paddle/Stripe/PayLetter) · SSO 서버 · MFA

### 프론트엔드

| sisyphus | 신규 | 변경 |
|---|---|---|
| `meeting-recorder.js` 녹음부 (3539~4110) | `packages/core/recorder/` | TS 이식. **일시정지 정책 통일** |
| `meeting-recorder.js` 업로드부 (4113~4400) | `packages/core/upload/` | presign 엔드포인트 교체 |
| `shared/utils/pending-uploads.js` | `packages/core/upload/queue.ts` | **거의 그대로.** IndexedDB 로직 유지 |
| `meeting-recorder.js` 화자/전사부 (2416~3470, 5362~5960) | `packages/core/domain/` + `apps/web/` | 로직/렌더 분리 |
| `meeting-recorder.js` 요약부 (1678~2290) | 동일 | `source` 점프 로직 유지 |
| `meeting-recorder.js` 플레이어 (2960~3280) | `packages/core/` + UI | webm duration 보정 유지 |
| `project-home.html` 1287~1920 | `apps/web/routes/meetings/` | React 컴포넌트로 재작성 |
| `meeting-recorder.css` (3,941줄) | `apps/web/` 스타일 | `styles.css`(872KB) 의존 제거. 필요한 것만 |
| `mobile.js` 미팅부 | **삭제** | `packages/core` 재사용으로 대체 |
| `webapp/s3-upload.js` | `packages/core/upload/presign.ts` | 축소 |

**버림**: `CoreUI`, `JustChatCore/UI`, `CookieDisplay`, `MeetingVideo`,
`ToolConfig`, 위젯 시스템, `MeetingRecorderWidget.js`

---

## devkanban → voice-recording

| devkanban | 신규 | 변경 |
|---|---|---|
| `billing/plan.ex` | `vr/billing/plan.ex` | 워크스페이스/엔터프라이즈 필드 제거 |
| `billing/plan_revision.ex` | `vr/billing/plan_revision.ex` | 런타임/동시실행 필드 제거 |
| `billing/subscription.ex` | `vr/billing/subscription.ex` | `organization_id`→`account_id`, 결제 필드 축소 |
| `billing/credit_lot.ex` | `vr/billing/credit_lot.ex` | `held` 관련 제거 |
| `billing/credit_ledger_entry.ex` | `vr/billing/credit_ledger_entry.ex` | 환불/역결제 소스 제거 |
| `billing/credits.ex` | `vr/billing/credits.ex` | FIFO 소비 로직 그대로 |
| `billing/monthly_grant_worker.ex` | `vr/workers/monthly_grant_worker.ex` | 그대로 |
| `billing/credit_expiry_worker.ex` | `vr/workers/credit_expiry_worker.ex` | 그대로 |
| `billing/billing_audit_log.ex` | `vr/billing/billing_audit_log.ex` | 그대로 |
| `billing/commerce_settings.ex` | `vr/billing/commerce_settings.ex` | 그대로 |
| `live/admin/commerce_plans_live.ex` | `vr_web/live/admin/plans_live.ex` | 축소 |
| `docs/billing-commerce-design.md` | [06-billing.md](06-billing.md) | 요약 반영 |

**이식 안 함**: 결제 전반(Order/Payment/Provider/Webhook/Refund/Reconciliation),
오토충전, 엔터프라이즈 계약, 트라이얼 전환, sunset/scheduled change, 크레딧 팩,
워크스페이스 런타임 계량

---

## n8n 워크플로 → 직접 구현

| n8n | 신규 | 확보 상태 |
|---|---|---|
| `get-upload-url` (v2) | `vr/storage/s3.ex` | ✅ SigV4 presign 로직 전체 확보. `ExAws.S3.presigned_url/5`로 대체 |
| `autosquad-meeting-summary` | `vr/summarize/` | ✅ 프롬프트 · 출력 스키마 · 파라미터 전체 확보 |
| `estimate_token_and_callback` | 불필요 | LLM 응답에서 토큰 사용량을 직접 받아 원장 기록 |

### presign 이식 요점

| 항목 | 값 |
|---|---|
| 서명 | AWS Signature V4 쿼리스트링 |
| 메서드 / 페이로드 | `PUT` / `UNSIGNED-PAYLOAD` |
| 서명 헤더 | `content-disposition;content-type;host` |
| 만료 | 1800초 |
| 다운로드 | CDN 도메인 별도 |

> n8n 워크플로는 SHA256/HMAC을 순수 JS로 직접 구현해 뒀지만,
> Elixir에서는 `ExAws`가 처리하므로 **그 부분은 이식하지 않는다.**

### 요약 이식 요점

- 직렬화 규약 `[<session_id>|<speaker>|<HH:MM:SS>] 발화` **유지**
- 라벨 파싱 규칙(원문 그대로 추출, 축약·번역 금지, 못 읽으면 빈 문자열, 날조 금지) **유지**
- 출력 스키마 **유지** → 기존 `summary_data` 소비 코드가 그대로 동작
- `temperature 0.2`, `maxOutputTokens 16384` **유지**
- 프롬프트를 리포 안에 파일로 두고 버전 관리 (n8n 대비 개선점)

---

## 알려진 결함 (이식하면서 고칠 것)

sisyphus 코드를 읽으며 실제로 확인한 문제들이다. 그대로 옮기면 같이 옮겨간다.

| # | 문제 | 근거 | 조치 |
|---|---|---|---|
| B1 | **데스크톱 일시정지 후 재개가 동작하지 않음** | `setupNewMediaRecorder()`가 정의되지 않은 `getSupportedMimeType()`(:3772)과 `startWaveform()`(:3795)을 호출. 실제 정의는 `getSupportedAudioMimeType()`, `drawWaveform()`. 배포본(`priv/static`)도 동일 | 일시정지 정책을 `pause()`/`resume()`로 통일하며 해소 |
| B2 | **데스크톱/모바일 일시정지 의미가 다름** | 데스크톱=세션 분할, 모바일=한 세션 유지 | `packages/core`에 단일 구현 |
| B3 | **언어 코드 불일치** | 데스크톱 HTML `<option>`은 `zh-CN`/`zh-TW`인데 JS `LOCALE_MAP`은 `cmn-Hans-CN`/`cmn-Hant-TW`. 모바일은 `cmn-*`로 맞음 | 상수 한 곳에서 관리 |
| B4 | **문서가 코드와 불일치** | `docs/MEETING_RECORDER.md`가 없는 `meeting-recorder.html`을 참조하고, 상태값을 `recording/completed`로 적었으나 실제는 `active/completed/archived` | 이 문서 세트로 대체 |
| B5 | **AWS 키가 리포에 평문 커밋** | `n8n-workflows/misc/get-upload-url.json` 외 2개 파일 | 신규 리포는 gitleaks로 차단. **sisyphus 쪽은 키 로테이션 필요** |
| B6 | **모바일에 URL 라우트 없음** | 오버레이 + 내부 상태. 딥링크·뒤로가기 불가 | 단일 라우트 체계로 해결 |
| B7 | **i18n 하드코딩 혼재** | 한국어 리터럴과 `getI18nString(key, fallback)`이 섞여 있음 | 전부 키로 정리 |
| B8 | **클라이언트가 준 오디오 주소를 서버가 그대로 믿음** | 이 앱 초기 구현이 sisyphus 흐름을 그대로 옮긴 결과. `upload_changeset`이 `audio_url`을 검증 없이 저장하고, 전사·분할 워커가 `Req.get(url, max_redirects: 5)`로 따라갔다 = **SSRF** (인증된 사용자가 사설망·메타데이터 엔드포인트로 서버를 보낼 수 있음) | presign 이 키를 정해 `recording_sessions.storage_key` 에 기록하고 `audio_url` 은 서버가 만든다. 워커는 `Storage.own_object_url?/1` 를 통과한 주소만 `max_redirects: 0` 으로 받는다 |
| B9 | **Viewer 오디오 마스킹이 무력** | `recording_key/4` 가 `meeting_id`·`session_id`·`started_at_unix`·확장자로 완전히 결정되는데 그 값들이 Viewer 응답에 다 들어 있고, `public_url/1` 은 서명이 없다. 필드만 지워도 키를 조립하면 원본을 받는다 | `audio_href` → `GET /api/sessions/:id/audio` → 권한 재판정 후 **presigned GET 302**. 버킷은 비공개 전제 |
| B11 | **게스트 join 이 클라이언트가 준 `member_id` 를 신뢰** | `guest_link_controller.ex` 가 `params["member_id"]` 존재만으로 `guest_link_enabled` 검사와 PIN 검사를 **동시에** 건너뛰었다. 이 라우트는 세션조차 없는 `:public_api` 파이프라인에 있어 값을 검증할 방법이 없었다 | 신원 판정에 요청 본문을 쓰지 않는다. 게스트가 볼 회의는 서버의 게스트 세션이 정한다 |
| B12 | **게스트 채팅이 링크 유효성을 안 봄** | `list_messages`/`create_message` 가 `deleted_at` 만 걸러, 만료·비활성·소진된 링크로도 읽고 쓸 수 있었다 | 게스트 경로 전부가 `guest_authorize/2` 한 관문을 지난다 |
| B13 | **`use_count` 가 비원자적이고 시점도 틀림** | 검사 후 별도 쿼리로 증가 → 동시 요청이 `max_uses` 를 넘긴다. 게다가 join 마다 증가해 새로고침이 1회성 링크를 태웠다 | 조건부 UPDATE 한 문장. 게스트 세션이 실제로 발급될 때만 증가 |
| B14 | **PIN 생성이 CSPRNG 가 아니고 범위도 틀림** | `:rand.uniform(899_999) + 100_000` — 예측 가능하고 `100000` 이 절대 안 나온다. 평문 컬럼에 저장되고 `?pin=` 쿼리스트링으로 URL 에 실려 브라우저 히스토리·리퍼러·액세스 로그로 샜다 | CSPRNG + 균등 분포, Bcrypt 저장, URL 에 싣지 않음 |
| B10 | **아카이브가 잠금이 아니었음** | `ensure_active` 가 세션 생성에만 걸려 있어, 아카이브한 회의의 전사본·화자를 lv1 이 계속 고칠 수 있었다 | 업로드 · presign · 전사 · 전사본 수정에 `ensure_mutable/1` 추가 (`422 meeting_archived`) |

---

## 이식 시 주의점

1. **STT 클라이언트는 손대지 말 것.** GCS 왕복 · 폴링 · 결과 파싱 · 임시파일 정리까지
   실전에서 다듬어진 코드다. 설정 소스만 바꾸고 로직은 그대로 옮긴다.
2. **IndexedDB 업로드 큐도 그대로.** 유실 방지 순서(저장 → 업로드 → 성공 시 제거)가
   핵심이고 이미 검증되어 있다.
3. **화자 2계층 구조를 단순화하지 말 것.** `segments[].speaker`와 `speaker_map`을
   합치고 싶어지지만, 세그먼트 단위 교정과 화자 단위 매핑은 서로 다른 조작이다.
4. **요약 `source` 규약을 느슨하게 만들지 말 것.** 요약 클릭 → 오디오 점프가
   이 제품의 핵심 UX이고, 그건 전적으로 프롬프트의 원문 추출 규칙에 달려 있다.

