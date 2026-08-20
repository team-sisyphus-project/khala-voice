# 14. 출처 — 무엇이 어디서 왔는가

이 앱은 두 기존 제품에서 가져온 것이 많다. **어느 것이 어디서 왔는지 추적할 수 있어야 한다.**

- 원본이 고쳐지면 여기도 고쳐야 하는지 판단할 수 있다
- 왜 이렇게 생겼는지 물었을 때 답할 수 있다
- 원본의 결정 근거를 다시 발굴하지 않아도 된다

## 원본 두 곳

| 표기 | 리포 | 무엇을 가져왔나 |
|---|---|---|
| **sisyphus** | `autosquad/sisyphus` | 회의 녹음 기능 전체 — 도메인 · 전사 파이프라인 · 권한 |
| **devkanban** | `devkanban` (MS / ManualSquad) | 모바일 디자인 시스템 전체 · 요금 정책(플랜 · 크레딧) |
| **khala** | `khala` | 브랜드(이름 · 아이콘) · 인트로 화면 |

> 표기 규칙: 코드 주석과 문서에 `sisyphus 에서 이식` / `devkanban 에서 이식` 을 남긴다.
> 원본 파일 경로를 함께 적어 바로 찾아갈 수 있게 한다.

---

## sisyphus 에서 온 것

### 도메인

| 이 앱 | sisyphus 원본 | 변경 |
|---|---|---|
| `VR.Meetings.Meeting` | `lib/sisyphus/meetings/meeting.ex` | `project_id` 제거 · `meeting_type` 제거 · 레거시 필드 제거 · `member_id`→`account_id` |
| `VR.Meetings.RecordingSession` | `lib/sisyphus/meetings/recording_session.ex` | 거의 그대로 |
| `VR.Meetings` | `lib/sisyphus/meetings.ex` | 아카이브(벡터DB) · 화상회의 관련 제거 |
| `VR.Access.AccessLevel` | `lib/sisyphus/access/access_level.ex` | `project_members`→`all_friends`, 조직 개념 제거, 게스트 역할 추가 |
| `VR.Sharing.SharedLink` | `lib/sisyphus/shared_links/shared_link.ex` | `granted_role` 추가, 화상 관련 제거 |
| `VR.Friends.FriendInvitation` | `lib/sisyphus/organizations/invitation.ex` | 역할 필드 제거 → 친구 초대로 전환 |
| `VR.Accounts.Account` | `lib/sisyphus/accounts/account.ex` | MFA · PasswordHistory · EmailHashHistory 제거 (MFA 는 어드민 전용으로 나중에 재도입) |
| `VR.System.SystemConfig` | `lib/sisyphus/system/system_config.ex` | 키 목록 확장 · 레지스트리 방식으로 재구성 |
| `VR.Vault` / `VR.Encrypted.Binary` | `lib/sisyphus/vault.ex` | 그대로 (Cloak AES-256-GCM) |
| `VR.IdGenerator` | `lib/sisyphus/id_generator.ex` | 접두사 목록만 이 앱에 맞게 |

### 전사 파이프라인

| 이 앱 | sisyphus 원본 | 변경 |
|---|---|---|
| `VR.Transcription.GoogleSTT` | `lib/sisyphus/meetings/google_stt.ex` (997줄) | 설정 소스를 `VR.Config` 로. **Agora 전용 경로 제거** (HLS `.m3u8` 다운로드 · MPEG-TS 변환) |
| `VR.Transcription.Audio` | `lib/sisyphus/meetings/audio_splitter.ex` | 거의 그대로. 이름만 `AudioSplitter` → `Audio` (길이 측정·변환도 하므로) |
| `VR.Workers.TranscriptionWorker` | `workers/meeting_transcription_worker.ex` | 과금 호출부를 `VR.Transcription.charge/2` 로 교체 |
| `VR.Workers.AudioSplitWorker` | `workers/audio_split_worker.ex` | 업로드 경로를 `VR.Storage` 로 교체 |
| 디코딩 설정 표 (`explicitDecodingConfig`) | `google_stt.ex` `get_decoding_config/1` | mp2t(Agora) 항목만 제거 |
| 단어→화자 그룹핑 · 인접 병합 | `google_stt.ex` `group_words_by_speaker/1` · `merge_short_segments/1` | 그대로 |
| JWT 서명 → 액세스 토큰 | `google_stt.ex` `sign_jwt/2` · `exchange_jwt_for_token/1` | 그대로 |
| `VR.Workers.SummaryWorker` | `workers/meeting_summary_worker.ex` | **n8n 호출 → LLM 직접 호출로 교체** |

### 프론트엔드

| 이 앱 | sisyphus 원본 | 변경 |
|---|---|---|
| `packages/core/recorder` | `assets/webapp/meeting-recorder.js` 3539~4110 | TS 이식 · **일시정지 정책 통일** · 중단 감지 추가 |
| `packages/core/upload` | `assets/shared/utils/pending-uploads.js` | **거의 그대로.** IndexedDB 유실 방지 순서 유지 |
| `packages/core/upload/uploader` | `meeting-recorder.js` 4113~4400 | presign 엔드포인트 교체 · XHR 진행률 추가 |
| 화자 2계층 구조 | `meeting-recorder.js` 2416~3470 | 그대로 (`segments[].speaker` + `speaker_map`) |
| 화자 팔레트 10색 × 3단계 | `meeting-recorder.js` `SPEAKER_PALETTE` | 그대로 |
| 녹음 UI 규격 | `assets/webapp/meeting-recorder.css` | 타이머 48px/300 · 파형 240px · 버튼 64px 원형 |
| `packages/core/domain/transcript` | `meeting-recorder.js` 2416~3470 · 5362~5960 | TS 이식 · 순수 함수로 분리 (렌더링과 분리해 테스트 가능하게) |
| 화자 색 = **등장 순서 고정** | `meeting-recorder.js` `assignSpeakerColors` | 그대로. 이름을 바꿔도 색이 유지돼야 "아까 파란 사람"이 살아남는다 |
| 인접 세그먼트 자동 병합 | `meeting-recorder.js` `mergeAdjacentSegments` | 그대로. 화자를 바꾸면 앞뒤가 한 덩어리가 된다 |
| 세그먼트 분할 = 글자 수 비율 | `meeting-recorder.js` `splitSegmentAt` | 그대로. 정확한 시각은 알 수 없으니 비례 배분한다 |
| `original_segments` 원본 보존 | `meeting-recorder.js` 5362~5960 | 그대로. 편집해도 전사 직후 값을 잃지 않는다 |
| 통합 오디오 플레이어 (하나만) | `meeting-recorder.js` 2960~3280 | 그대로 + webm `duration: Infinity` 회피 (`fixAudioDuration`) |

### AI 요약 (M4)

sisyphus 는 n8n 워크플로에 위임했다. **이 앱은 LLM 을 직접 호출한다** (사용자 요구: n8n 제거).

| 이 앱 | 원본 | 변경 |
|---|---|---|
| `VR.Summarize.Serializer` | sisyphus n8n `autosquad-meeting-summary.json` | 직렬화 규약 그대로 + 화자 이름의 구분자 제거 추가 |
| `VR.Summarize.Prompt` | 〃 시스템 프롬프트 | 그대로. n8n 노드에 있던 것이 코드로 내려옴 |
| `VR.Summarize.Prompt.schema/0` | 〃 출력 스키마 | 그대로 |
| `VR.Summarize.Normalizer` | — | **이 앱에서 새로 씀.** n8n 은 모델 출력을 그대로 흘려보냈다 |
| `VR.Summarize.LLM` + 어댑터 3종 | — | 〃 (n8n 노드가 하던 일) |
| `SummaryWorker` | sisyphus n8n 웹훅 호출부 | Oban 잡으로 대체 |
| `VR.Summarize.Dev` | sisyphus `stt.dev_mode` 발상 | 요약판. 실제 전사에서 인용을 뽑는다 |
| 토큰 단가 계산 | **devkanban** `MS.Meters.UsageRecorder.price_tokens/3` | 계산식·필드명 그대로 (`input_price_usd_per_1m` · `margin_rate`) |
| 원장 멱등 열쇠 파생 | **devkanban** `usage_idempotency_key/2` | 그대로 — 오버드래프트는 고정 접미사 |

### 분류 · 검색 (M5)

| 이 앱 | 원본 | 변경 |
|---|---|---|
| `VR.Taxonomy.Topic` | sisyphus `lib/sisyphus/topics/topic.ex` | 테이블 `categories`→`topics` · `project_id`→`owner_id` · `title`+`display_label`→`name` · `description` 제거 · 자유HEX→팔레트 키 · `sort_order`/`deleted_at` 추가 |
| `VR.Taxonomy.Label` | sisyphus `lib/sisyphus/labels/label.ex` | 위와 동일. 이름 상한 20자는 원본 그대로 |
| `VR.Taxonomy.Color` | sisyphus `assets/shared/utils/color-picker-utils.js` `DEFAULT_PALETTE` | HEX 값만 가져오고 **방식을 바꿨다** — 자유 HEX 대신 팔레트 키. 테마가 넷이라 임의 색이 네 배경 모두에서 읽힌다는 보장이 없다 |
| `VR.Taxonomy` | sisyphus `topics.ex` · `labels.ex` | CRUD 골격만. **소프트 삭제 + detach · 사용자 정렬 · 소유권 검증은 신규** |
| `Meetings.filter_participant/2` | sisyphus `lib/sisyphus/archives.ex` 참여자 필터 | 조직·author 개념을 걷어내고 Reviewer / owner / Contributor 세 자리로 축소 |
| 아카이브 필터 UI | sisyphus 아카이브 검색 화면 | URL 쿼리 동기화는 **신규** (sisyphus 모바일에는 URL 라우트가 아예 없었다 — B6) |

### 공개 범위 UI (M5)

| 이 앱 | 원본 | 변경 |
|---|---|---|
| `packages/core/domain/permissions` | sisyphus `assets/shared/components/core-ui.js` (`VIEW_SCOPES`, `normalizeViewScope`) | `selected_members`→`selected_friends` · `project_members`→`all_friends` · 저장 키 `memberIds`→`accountIds` · 파스텔 색 하드코딩 제거(테마가 넷이라 라이트 전용 색이 안 읽힌다) |
| `VisibilityPanel` · 범위 선택 | sisyphus `assets/webapp/meeting-recorder.js` 공개범위 popover | **popover → 인라인 라디오** (선택지 4개의 설명이 판단의 핵심이라 접으면 오설정을 부른다) · 라벨을 Reviewer/Contributor/Viewer 영문 고정 (원본은 "검토자"·"관계자") · **"나만" 함정 경고 신규** · **Reviewer 양도 확인 + 권한 상실 시 이탈 처리 신규** · 낙관적 갱신 제거 |
| `FriendPicker` | sisyphus `core-ui.js` 멤버 피커 | member→friend · 다중 선택은 **닫을 때 1회만** 저장 (체크마다 PATCH 를 보내면 앞 요청이 끝나기 전에 다음이 출발해 마지막 선택이 유실된다) |

### 공유 · 게스트 (M5)

| 이 앱 | 원본 | 변경 |
|---|---|---|
| `VR.Sharing.SharedLink` | sisyphus `lib/sisyphus/shared_links/shared_link.ex` | `resource_type`+`resource_id` 다형 참조 → `meeting_id` 단일 FK · `organization_id`/`project_id` 제거 · **`granted_role` 신규** · 평문 `token` → sha256 `token_hash`+`token_prefix` · 평문 `pincode` + `:rand.uniform` → Bcrypt `pin_hash` + CSPRNG (원본은 CSPRNG 가 아니었고 범위가 어긋나 `100000` 이 안 나왔다) · changeset 이 `:id`/`:token`/`:use_count` 를 cast 하던 것을 막음 |
| `VR.Sharing` | sisyphus `lib/sisyphus/shared_links.ex` | `validate_and_use_token/1` 의 검사-후-증가 2단 쿼리를 **조건부 UPDATE 한 문장**으로 (원본은 동시 요청이 `max_uses` 를 넘길 수 있었다) · 사용 횟수를 "링크를 열 때"가 아니라 "게스트 세션이 실제로 발급될 때" 증가 (원본은 새로고침이 1회성 링크를 태웠다) · 폐기가 게스트 세션까지 끊는다 (원본은 `is_active` 만 껐다) · 화상 세션 헬퍼와 `resource_type` 분기 제거 |
| `VR.Sharing.GuestSession` | **출처 없음 — 신규** | sisyphus 에는 게스트 세션이 아예 없었다. 게스트 신원이 브라우저 JS 변수(`assets/webapp/video-call-guest.js`)라 서버가 "들어와 있는 게스트"를 몰랐다 |
| `VR.Sharing.ShareAttempt` | 이 리포의 `VR.Accounts.LoginAttempt` | 같은 모양. `login_attempts` 재사용을 피한 이유는 `email` 컬럼 의미가 흐려지기 때문 |
| `VRWeb.API.Public.ShareController` | sisyphus `lib/sisyphus_web/controllers/guest_link_controller.ex` | **URL 에서 회의 id 를 없앴다** · `params["member_id"]` 신뢰 제거 (원본은 이 값으로 `guest_link_enabled` 와 PIN 을 동시에 우회할 수 있었다) · fail-open 검사를 fail-closed 로 · 서버 렌더 HTML 오류 페이지 대신 JSON |
| `VRWeb.API.ShareLinkController` | sisyphus `lib/sisyphus_web/controllers/shared_link_controller.ex` | lv0/lv1 → **lv0 만** · 프로젝트 멤버십 → 그 회의의 Reviewer (원본은 멤버면 누구든 평문 토큰·PIN 을 읽고 남의 링크를 죽일 수 있었다) · 활성 링크 재사용 대신 여러 개 발급 |
| `VR.LogRedactor` | **출처 없음 — 신규** | 공유 토큰이 URL 경로에 있어 Phoenix 요청 로그에 평문으로 남는 문제를 로거 앞단에서 막는다 |
| `VR.Meetings.Export` | sisyphus `assets/webapp/meeting-recorder.js` `exportTranscriptMarkdown()` | 클라이언트 Blob → **서버 렌더링** (원본은 데스크톱 `.md` / 모바일 `.txt` 로 갈렸다) · 절대 벽시계 → **세션 내 상대 시각** (요약 `source.time_label` 과 시계를 맞추기 위해) · 세션 경계 표시 추가 · **요약 포함** (원본에 없었다) · 파일명 새니타이즈 + RFC 5987 |
| `VR.Meetings.Speakers` | 〃 화자명 3단 폴백 | `member_id` → `account_id`. `Serializer` 와 폴백만 공유하고 새니타이즈는 분리 (한쪽은 지우고 한쪽은 이스케이프해야 한다) |

### 규약 · 정책

| 항목 | 출처 | 비고 |
|---|---|---|
| 전사 직렬화 `[session_id\|speaker\|HH:MM:SS] 발화` | sisyphus n8n `autosquad-meeting-summary.json` | 프롬프트와 합의된 규약. 바꾸면 요약 출처 추출이 깨진다 |
| `summary_data` 스키마 | 〃 | `one_liner` · `decisions` · `action_items` · … |
| 요약 프롬프트 규칙 | 〃 | 원문 그대로 추출 · 축약/번역 금지 · 못 읽으면 빈 문자열 |
| S3 SigV4 presign 규격 | sisyphus n8n `get-upload-url.json` | 서명 헤더 `content-disposition;content-type;host` · 만료 1800초 |
| 권한 4단계 (lv0~lv3) | `lib/sisyphus/access/access_level.ex` | 명칭만 Reviewer/Contributor/Viewer 로 통일 |
| MIME 폴백 체인 | `meeting-recorder.js` `getSupportedAudioMimeType` | webm → mp4(Safari) → ogg |
| 20분 분할 임계값 | `workers/meeting_transcription_worker.ex` | Google STT batchRecognize 제한 |

### 이식하지 않은 것 (sisyphus 고유)

조직 · 프로젝트 · 태스크 · 저스트챗 · 커뮤니케이션(CRM) · 다이제스트 ·
벡터DB 아카이브 · 인박스/멘션 · 에이전트/MCP · Agora 화상회의 ·
결제(LemonSqueezy/Paddle/Stripe/PayLetter) · SSO 서버 · 위젯 대시보드

---

## khala 에서 온 것

서비스 이름이 **KHALA VOICE** 다. 브랜드가 khala 계열이라 아이콘과 인트로를 거기서 가져왔다.

| 이 앱 | khala 원본 | 변경 |
|---|---|---|
| `backend/priv/static/images/brand/*` | `frontend/public/*` | **그대로** (원본 아이콘 · 워드마크 보관용) |
| `backend/priv/static/images/icon-*.png` | `frontend/public/icon-bg-*.png` 의 구도 | **다시 그렸다** — 종이비행기를 **마이크**로, 파란 별빛을 **빨강**으로. 배치(좌하단 오브젝트 + 우상단 별빛)와 검은 배경은 원본 그대로 |
| `apps/web/src/components/IntroScreen.tsx` | `frontend/src/components/intro/IntroScreen.tsx` | 단계(로고 → 퇴장)와 세션당 1회 규칙은 그대로. PWA 복귀 스플래시는 **안 가져옴**(녹음 중 복귀가 잦아 방해가 된다), 워드마크는 이미지 대신 글자(테마를 따라가야 한다) |
| `.vr-intro*` CSS | `globals.css` 의 `.kh-intro*` | 타이밍 그대로, 색만 테마 토큰으로 |

---

## devkanban 에서 온 것

### 디자인 시스템 → [12-design-system.md](12-design-system.md)

2026-08-20, 사용자 요청으로 **모바일 디자인을 devkanban 것으로 통째로 바꿨다.**
그전에는 토큰과 테마만 가져다 마크업은 이 앱이 따로 갖고 있었는데, 버튼의 누름
반응 · 헤더 표현 · 인풋 · 모달의 글래스모피즘까지 같기를 원한 요구라 **CSS 를
원본 그대로 두고 마크업(클래스 이름)을 맞추는 쪽**으로 갔다.

스타일은 `packages/ui-styles/` 한 곳에 있고 **웹앱(React)과 LiveView 가 같은
파일을 읽는다.** 두 벌로 복사하면 반드시 갈라진다 — sisyphus 가 같은 로직을
데스크톱/모바일에 두 벌 두었다가 동작이 갈린 것과 같은 실수다.

| 이 앱 | devkanban 원본 | 변경 |
|---|---|---|
| `packages/ui-styles/devkanban/tokens.css` | `mobile/src/styles/tokens.css` | **그대로** |
| 〃 `base.css` | `mobile/src/styles/base.css` | **그대로** |
| 〃 `components.css` | `mobile/src/styles/components.css` | **그대로** |
| 〃 `redesign.css` | `mobile/src/styles/redesign.css` | **그대로** |
| 〃 `media-skin.css` | `mobile/src/styles/media-skin.css` | **그대로** (연필·수채화 매체 스킨) |
| 〃 `press.css` | `mobile/src/styles/press.css` | **그대로** (누름 반응 시스템) |
| 〃 `game-skin.css` | `mobile/src/styles/game-skin.css` | **그대로** |
| `packages/ui-styles/overrides.css` | — | **이 앱 고유.** 아래 "덮은 것" 참조 |
| `apps/web/src/ui/*` | `mobile/src/components/*` | 마크업 그대로. `Drawer`(햄버거) · `MorphingText` 는 안 가져옴 |
| `apps/web/src/ui/press.ts` | `mobile/src/press.ts` | **그대로** |
| `apps/web/src/ui/IconButton.tsx` | — | **덧붙임.** 원본은 TopAppBar 안에 인라인으로 두었는데 화면마다 액션이 달라 뽑았다. 모양은 원본과 같다 |
| `apps/web/src/ui/Sheet.tsx` | `mobile/src/screens/BoardSettingsSheet.tsx` 의 `BoardSheet` | Esc 로도 닫는다 (데스크톱에서도 쓴다) |
| `backend/assets/css/legacy-tokens.css` | — | **이 앱 고유.** 옛 토큰 이름을 devkanban 토큰에 연결하는 다리. 화면을 옮길수록 줄어야 한다 |
| DungGeunMo 폰트 | `priv/static/fonts/DungGeunMo.woff` | 그대로 (게임 테마 도트 폰트) |

**`overrides.css` 에서 덮은 것** — 왜 덮었는지가 중요하다

| 덮은 것 | 이유 |
|---|---|
| 액센트를 오렌지(hue 45) → **빨강**(hue 25) | 이 서비스의 키 색. 명도·채도 구조는 그대로 둬 대비 검증을 다시 하지 않는다 |
| `.mobile-section--card` (유리 카드) | devkanban 은 한 화면이 한 흐름이지만 이 앱은 한 화면에 성격이 다른 덩어리가 여럿 선다. 재료는 원본 `.mobile-pwa-card` 와 같다 |
| 카드 안에서 `--mobile-surface-inset` 재정의 | 원본 inset(87%)은 캔버스(94%) 기준이라 유리 카드(≈97%) 위에서는 회색 판때기로 읽힌다 |
| 섹션 간격 36px → 14px, 좌우 24px → 16px | 이 앱은 한 화면에 카드가 대여섯 개 선다 |
| 최상위 탭 화면의 상단바 여백 제거 | 뒤로가기가 없으니 상단바가 자리를 잡을 이유가 없다. 제목이 맨 위에 붙고 액션이 같은 줄에 선다 |
| 뎁스 화면의 제목 캡슐을 항상 표시 | 원본은 스크롤 전까지 숨긴다. 이 앱의 뎁스 화면은 본문에 제목을 두지 않아 그러면 "여기가 어디인지"가 사라진다 |
| `.bottom-nav a` 규칙 추가 | LiveView 쪽 탭은 `<a>` 다. 원본 CSS 는 `button` 만 본다 |
| 칩의 점(`::before`) 제거 | 사용자 요청 — 칩 자체가 이미 색을 들고 있다 |
| 연필 스킨을 이 앱의 상자에 확장 | `media-skin.css` 는 devkanban 마크업(`.mobile-row` · `.mobile-button` …)만 겨냥한다. 이 앱이 새로 만든 `.mobile-section--card` · `.vr-*` 는 스킨이 모르는 이름이라 연필 테마에서 혼자 매끈한 사각형으로 남았다. **같은 재료**(`--pc-stroke` · `--pc-ink`)를 빌려 우리 이름에 다시 걸었다 |
| 녹음 버튼 마이크를 `FILL 1` 로 | 빨간 원 안의 외곽선 마이크는 획이 가늘어 비어 보인다. `opsz` 도 실제 렌더 크기와 맞춘다 |
| 게임 테마에서 아이콘 글꼴 되돌리기 | `[data-theme="game"] *` 가 **모든 요소**의 글꼴을 도트 폰트로 바꾼다. devkanban 은 아이콘이 인라인 SVG 라 안 걸렸는데, 이 앱은 Material Symbols(합자 폰트)라 아이콘 **이름이 글자 그대로** 찍혔다 |

**devkanban 의 결정 기록**

- 픽셀 테마는 2026-08-08 반려 (`docs/theme-medium-skin-plan.md` 개정 주석) —
  "선 과다 · 레이아웃 수치까지 바꿔야 성립"
- 2026-08-17 게임 테마로 부활 (`themes/game.css` 헤더) —
  "게임 테마는 애초에 레이아웃 수치를 바꾸는 테마이고, 설정에 노출되지 않는 숨은 테마라
  일반 사용자에게 강제되지 않는다. 그래서 반려된 픽셀 사양을 여기로 들여왔다."
- **이 앱은 게임 테마를 설정에 노출한다** (devkanban 은 숨김) — 사용자 요청

### 아이콘

devkanban 의 인라인 SVG 레지스트리(`mobile/src/Icon.tsx`)를 그대로 가져왔다가
**되돌렸다.** 이 앱이 쓰는 이름(`ios_share` · `arrow_upward` · `settings` …)이
레지스트리에 없어 화면마다 빈 동그라미나 이름 글자가 그대로 나왔다.
사용자 판단(2026-08-20): "아이콘은 머터리얼 아이콘 그냥 쓰자."

지금은 `Icon` 이 **Material Symbols Rounded** 글리프를 그린다 — LiveView 쪽과
같은 세트다. 클래스 이름(`mobile-icon`)은 devkanban CSS 가 걸려 있어 유지한다.

### 어드민 MFA 데드락

| 이 앱 | devkanban 원본 | 변경 |
|---|---|---|
| `AuthLive.MFAEnrollLive` + `SessionController.enroll/2` | `session_controller.ex` 의 `enroll/2` · `verify_enroll/2`, `session_html/enroll.html.heex` | **같은 해법.** 마크업은 이 앱 것이고, QR 라이브러리(`eqrcode`)는 들이지 않았다 — 인증기 앱은 대부분 키 직접 입력을 지원한다 |

**문제**: 2단계 인증이 의무인 계정(시스템 어드민)이 아직 켜지 않았으면 어디에도
못 들어가는데, 켜는 화면이 어드민 구역 안에 있으면 **자기 자신을 막는 문**이 된다.
신규 어드민은 DB 를 직접 건드리지 않는 한 영원히 들어갈 수 없었다.

**해법**: 등록 화면을 **로그인 흐름 안**(`/login/mfa/enroll`)에 둔다. 비밀번호는
통과했고 세션은 아직 없는 상태에서 등록을 마쳐야 로그인이 끝난다.

함께 막은 구멍: `MFA.verify/2` 가 `mfa_enabled: false` 인 계정에 `:ok` 를 돌려줬다.
로그인이 어드민을 무조건 코드 화면으로 보내므로, **MFA 를 안 켠 어드민은 아무 숫자나
넣어도 통과했다** — 2단계 인증이 있는 척하면서 실제로는 비밀번호 하나만 지키고 있었다.

### 요금 정책 → [06-billing.md](06-billing.md)

| 이 앱 | devkanban 원본 | 변경 |
|---|---|---|
| 설계 원칙 전체 | `docs/billing-commerce-design.md` | 결제 · 팩 구매 부분 제외 |
| `Plan` (가변 메타) | `lib/manualsquad/billing/plan.ex` | 워크스페이스 · 엔터프라이즈 필드 제거 |
| `PlanRevision` (불변 스냅샷) | `billing/plan_revision.ex` | 런타임 · 동시실행 필드 제거 |
| `Subscription` | `billing/subscription.ex` | `organization_id`→`account_id`, 결제 필드 축소 |
| `CreditLot` (FIFO 소비 단위) | `billing/credit_lot.ex` | `held` 관련 제거 |
| `CreditLedgerEntry` (append-only) | `billing/credit_ledger_entry.ex` | 환불 · 역결제 소스 제거 |
| **FIFO 소비 · `FOR UPDATE` 잠금** | `billing/credits.ex` `lock_available_lots/1` · `take_from_lots/5` | 보류(hold) 제거 |
| **오버드래프트 기록** | `billing/credits.ex` `consume_allow_overdraft/3` | 그대로 |
| **묶음별 idempotency_key 파생** | `billing/credits.ex` `ledger_option_attrs/4` 의 `key_part` | 그대로 |
| **`CreditConversionSetting`** | `billing/credit_conversion_setting.ex` | **그대로** — 싱글턴 USD→크레딧 환산 |
| **환산 공식** | `billing/credit_conversions.ex` | **그대로** |
| `PlanRevision.granted_credits/1` | `billing/plan_revision.ex:102` | 그대로 |
| `MonthlyGrantWorker` | `billing/monthly_grant_worker.ex` | 그대로 |
| `CreditExpiryWorker` | `billing/credit_expiry_worker.ex` | 그대로 |
| `BillingAuditLog` | `billing/billing_audit_log.ex` | 그대로 |
| `CommerceSettings` (용어 브랜딩) | `billing/commerce_settings.ex` | 그대로 |

**devkanban 의 확정 결정** (`docs/billing-commerce-design.md` §2)

1. 상업적 수정은 새 리비전을 만들고 기존 구독은 그랜드파더링된다
2. 대외 용어는 전역 1벌 + 로케일 오버라이드
3. 결제 제공자는 중립 (provider + external_id 컬럼만)
4. 플랜 월 지급은 기간 말 만료(이월 없음), 팩·관리자 지급은 명시적 만료가 없으면 무기한
5. 리비전마다 다중 통화 가격 맵
6. 회수는 잔액을 음수로 만들 수 없다

**이식하지 않은 것**: 결제 전반(Order/Payment/Provider/Webhook/Refund/Reconciliation) ·
오토충전 · 엔터프라이즈 계약 · 트라이얼 전환 · sunset/scheduled change ·
크레딧 팩 구매 · 워크스페이스 런타임 계량 · `PlanPricingPolicy`(판매 기간 · 미리보기)

---

## 두 원본이 겹치는 지점

같은 문제를 두 곳이 다르게 풀었을 때 어느 쪽을 택했는지.

| 항목 | sisyphus | devkanban | 이 앱의 선택 |
|---|---|---|---|
| **크레딧 환산** | 서비스별 `cookie_rate` (`ServicePricing`) | 싱글턴 USD→크레딧 (`credit_value_usd`) | **devkanban** — 실제 원가에서 파생돼 단가가 바뀌어도 한 곳만 고친다 |
| **반올림** | `max(round(...), minimum)` | `ceil` 고정 | **devkanban** — 올림이 사업자에게 안전하고 정책이 하나뿐이라 단순하다 |
| **디자인** | 라이트 전용 글래스모피즘 | 테마 4종 (매체 × 온도) | **devkanban** — 사용자별 테마 요구 |
| **액센트** | 빨강 `#f04452` | 오렌지 `oklch(65% .20 45)` | **sisyphus** — 녹음 버튼이 빨강이라 계열을 맞춘다 |
| **ID 체계** | 접두사 문자열 PK (`meet_…`) | 정수 PK + `public_id` | **sisyphus** — 하나로 끝나 단순하다 |
| **권한** | lv0~lv3 4단계 | — | **sisyphus** |
| **암호화** | Cloak + `Encrypted.Binary` | — | **sisyphus** |

---

## 이 앱 고유 (어느 쪽에도 없음)

| 항목 | 왜 새로 만들었나 |
|---|---|
| **친구 관계** (`Friendship`) | 두 원본 모두 조직·워크스페이스 기반이라 대응물이 없다 |
| **부트스트랩 어드민** | 설치 직후 입구를 열고, 실사용자 승격 후 닫는 절차 |
| **어드민 잠금 방지** | 마지막 어드민 강등·삭제 거부 |
| **어드민 전용 MFA + 개발 우회** | 시스템 어드민만 대상. 운영 외에서는 6자리 숫자 통과 |
| `VR.Config` 3단 해석 (DB→ENV→없음) | 오픈소스 공개 대비. sisyphus 는 `SystemConfig` 가 있었지만 레지스트리·폴백 체계는 없었다 |
| `VR.Storage` presign 직접 구현 | sisyphus 는 n8n 웹훅에 위임했다 |
| `VR.Summarize` LLM 직접 호출 | 〃 |
| `packages/core` 로직/UI 분리 | sisyphus 는 데스크톱·모바일에 로직을 두 벌 복사했다 |
| 지연 로드 테마 | devkanban 은 전부 번들에 넣는다. 이 앱은 모바일 우선이라 66KB 를 미룬다 |
| `mix vr.doctor` | 외부 의존이 많아 무엇이 왜 안 되는지 한 화면에 필요했다 |

---

## 원본에서 발견한 결함 (고쳐서 이식)

`sisyphus` 코드를 읽으며 실측 확인한 것들. 그대로 옮기면 같이 옮겨간다.
상세는 [10-porting-map.md](10-porting-map.md#알려진-결함).

| # | 결함 | 원본 위치 |
|---|---|---|
| B1 | 데스크톱 일시정지 후 재개가 동작하지 않음 (정의되지 않은 함수 호출) | `meeting-recorder.js:3772, 3795` |
| B2 | 데스크톱/모바일 일시정지 의미가 다름 | `meeting-recorder.js` vs `mobile.js` |
| B3 | 언어 코드 불일치 (`zh-CN` vs `cmn-Hans-CN`) | `project-home.html` vs `meeting-recorder.js` |
| B5 | **AWS 키가 리포에 평문 커밋** | `n8n-workflows/*.json` 3개 파일 |
| B6 | 모바일에 URL 라우트 없음 (딥링크 불가) | `mobile.js` 오버레이 |

---

## 유지 규칙

1. **원본에서 코드를 가져오면 파일 상단 `@moduledoc` 에 출처를 남긴다.**
   ```elixir
   @moduledoc """
   ...
   sisyphus `lib/sisyphus/meetings/google_stt.ex` 에서 이식.
   """
   ```
2. **이 문서의 표를 함께 갱신한다.** 코드 주석만 남기면 전체 그림이 안 보인다.
3. **원본과 달라진 점을 적는다.** "그대로"인지 "무엇을 바꿨는지"가 나중에 원본을
   다시 볼지 판단하는 기준이 된다.
4. **원본의 결정 근거도 옮긴다.** 왜 그렇게 됐는지가 사라지면 같은 논의를 반복한다.
