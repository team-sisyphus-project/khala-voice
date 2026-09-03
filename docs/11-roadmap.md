# 11. Roadmap

Every milestone must be independently deployable and verifiable.

## M0 — Foundation  ✅ Done

| Item | Deliverable |
|---|---|
| Repo structure | `backend/`, `packages/core/`, `apps/web/` |
| Phoenix app | Boots, Repo, Oban, Cloak (boot fails without `CLOAK_KEY`) |
| Config layers | `VR.Config` (DB → ENV → nil), `SystemConfig` schema |
| Secret defense | `.gitignore`, `.env.example`, gitleaks pre-commit + CI |
| CI | Compile · format · test · secret scan |
| Container | Dockerfile **with FFmpeg included** |

**Done when**: an empty app boots, secrets cannot be committed, and `ffmpeg -version` works inside the container.

**What was actually built** (pulled forward from the plan — since keys must be enterable
via the DB after deployment, the admin settings screen was included in M0):

- `VR.Config` — three-tier resolution DB → env var → nil, no literal defaults
- `VR.Config.Registry` — config key declarations. **The admin screen is generated from this**
- `VR.Vault` / `VR.Encrypted.Binary` — Cloak AES-256-GCM. Boot fails without `CLOAK_KEY`
- `SystemConfig` / `AuthProvider` / `LlmProvider` schemas + migrations
- Admin LiveView — dashboard · settings (grouped) · social login · LLM providers
- Oban (4 queues) · ExAws · Dockerfile (FFmpeg + UTF-8 locale) · CI (including gitleaks) · pre-commit hook
- 27 tests passing

## M1 — Accounts · Friends  ✅ Done

| Item |
|---|
| Account · AccountSession · AccountToken · LoginAttempt |
| Email signup · login · confirmation email · password reset |
| `AuthProvider` + social login ON/OFF (admin UI included) |
| Device session list · remote logout |
| FriendInvitation · Friendship, email/link invitations |
| Scheduled account deletion + `DeletionWorker` |

**Done when**: toggling a social provider in admin makes the login screen and OAuth routes
react together. Enabling one without keys does not expose it.

**Progress**

- [x] `VR.IdGenerator` — prefixed IDs (`acct_…`, `frnd_…`, `finv_…`)
- [x] `Account` · `AccountSession` · `AccountToken` · `LoginAttempt` schemas + migrations
- [x] `VR.Accounts` — signup · login · sessions · email tokens · attempt limits · scheduled deletion · social linking
- [x] `Friendship` · `FriendInvitation` schemas + migrations
- [x] `VR.Friends` — friend list · invitation create/accept/decline/cancel · block
- [x] 81 tests
- [x] Design system port — sisyphus tokens + `.vr-*` components ([12-design-system.md](12-design-system.md))
- [x] Web layer — login · signup · password reset · email confirmation
- [x] `VRWeb.UserAuth` — session cookie (http_only · SameSite=Lax · signed), session fixation defense
- [x] Invite code policy (`policy.invite_code_required`) + transactional consumption
- [x] Real OAuth flows — Google · GitHub, state CSRF defense, disabled providers return 404
- [x] Email delivery (confirmation · reset · friend invitation)
- [x] Admin auth switched to `Account.is_admin` + `mix vr.make_admin`
- [x] 96 tests
- [x] Friends screen — email/link invitations, sent-invitation management, acceptance screen
- [x] Account settings screen — profile · password · device sessions · scheduled deletion
- [x] `DeletionWorker` (hourly) · `InvitationCleanupWorker` (daily)

## M2 — Recording · Upload (core)  🔨 In progress

| Item |
|---|
| Meeting · RecordingSession schemas + API |
| `packages/core/recorder` — MediaRecorder · waveform · timer · **unified pause** |
| `packages/core/upload` — IndexedDB queue · retry · failure banner |
| `VR.Storage.S3` presign (ExAws) |
| Minimal `apps/web` UI — list · detail · recording |
| Basic SSE wiring |

**Done when**: recording → S3 upload → session registration works end to end, and
**something recorded in airplane mode uploads automatically once back online.**

**Progress**

- [x] `Meeting` · `RecordingSession` schemas + migrations (including pg_trgm search indexes)
- [x] `VR.Access.AccessLevel` — Reviewer / Contributor / Viewer, guest roles
- [x] `VR.Meetings` — permission-based reads, filtered lists, session management, transcription validation
- [x] `VR.Storage` + S3 presign (ExAws SigV4, n8n removed)
- [x] 12 REST API endpoints + Viewer masking
- [x] 137 tests
- [x] `packages/core/recorder` — MediaRecorder engine · waveform · **unified pause** · interruption detection
- [x] `packages/core/upload` — IndexedDB queue · sequential upload · retry · progress
- [x] `packages/core/api` — typed API client
- [x] Real-device spike page `/spike/recorder` + HTTPS dev setup
- [ ] **Mobile real-device background recording verification** ← top risk · [procedure](13-device-testing.md)
- [x] `apps/web` React SPA (Vite) — served by Phoenix at `/app`
- [x] `useRecorder` hook — wires the engine into React (waveform drawn directly on canvas)
- [x] Meeting list · detail · recording · session list · archive search
- [x] 4 themes (Light · Dark · Pencil · Game) — per-user setting · lazy load
- [x] Responsive — bottom tab bar (mobile) / top nav (desktop), same routes
- [x] System admin account management — promote · demote · delete + **lockout prevention**
- [x] Bootstrap admin (`mix vr.bootstrap_admin`) — promote a real user, then delete it to close the door
- [x] Admin-only MFA (TOTP) — non-production environments bypass with any 6-digit number
- [ ] Admin account management screen (`/_admin/accounts`)
- [ ] MFA setup screen
- [ ] Topic · Label CRUD + archive filter UI
- [ ] SSE connection (currently polling)

## M3 — Transcription · Speakers  ✅ Done

| Item |
|---|
| `GoogleSTT` port + `VR.Config` wiring + dev mode (mock responses) |
| `AudioSplitter` + `AudioSplitWorker` (split recordings over 20 minutes) |
| `TranscriptionWorker` |
| Transcription view (chat style) · unified audio player · segment highlighting |
| Speaker editing — chip changes · segment changes · add/delete · text editing · splitting · original restore · re-transcription |

**Done when**: a 30+ minute recording makes it through split → transcription → speaker mapping,
and the entire UI is viewable in dev mode without GCP credentials.

**Progress** — all ported from sisyphus ([14-provenance.md](14-provenance.md#transcription-pipeline))

- [x] `VR.Transcription.GoogleSTT` — batchRecognize · GCS round-trip · 5-second polling · temp-file cleanup
- [x] `VR.Transcription.Audio` — ffprobe duration · 19-minute splits · MP3 conversion (**verified with real FFmpeg runs**)
- [x] `TranscriptionWorker` — convert → STT → save → **credit metering** → aggregation
- [x] `AudioSplitWorker` — split over 20 minutes → create chunk sessions → delete original → re-enqueue
- [x] Dev mode — mock transcription without GCP keys (5 segments · 3 speakers)
- [x] `POST /api/sessions/:id/transcribe` + React transcribe button
- [x] `packages/core/domain/transcript` — speaker/segment manipulation logic (no UI framework)
- [x] Transcription view (chat style) · unified audio player · playing-segment highlight
- [x] Speaker editing — name · friend linking · add/delete · segment speaker change · text editing · splitting · original restore
- [x] `PATCH /api/sessions/:id/speakers` · `GET /api/friends`
- [x] Tests — 240 backend + 26 core (`node --test`)

**M3 complete.** Recordings over 30 minutes make it through split → transcription → speaker
mapping, and the entire UI is viewable in dev mode without GCP credentials.

## M4 — AI Summary  ✅ Done

| Item |
|---|
| `LLM.Client` + Gemini / Anthropic / OpenAI adapters |
| `LlmProvider` admin (keys · models · priority · fallback) |
| Prompt files + serialization · schema validation · normalization |
| `SummaryWorker` (auto / retry) |
| Summary view + **click a source → jump in the audio** |

**Done when**: clicking a summary item plays the corresponding utterance.
Switching providers in admin leaves the output schema unchanged.

**Progress**

- [x] `VR.Summarize.Serializer` — `[session_id|speaker|HH:MM:SS] utterance` serialization (sisyphus convention)
- [x] `VR.Summarize.Prompt` — system prompt + JSON schema (ported from the sisyphus n8n prompt)
- [x] `VR.Summarize.Normalizer` — normalization + **cross-checks `source` against the actual transcription to block fabrication**
- [x] `VR.Summarize.LLM` + Gemini / Anthropic / OpenAI adapters · fallback only on retry-worthy failures
- [x] `SummaryWorker` — unique per `meeting_id` · auto guard · forced retry
- [x] Dev mode — mock summary without keys. **Pulls quotes from the real transcription, so the jump is verifiable too**
- [x] Token metering — devkanban `price_tokens/3` formula ported (metering skipped when no unit price)
- [x] Admin — provider CRUD · unit prices · dev mode / auto-summary switches
- [x] `POST /api/meetings/:id/summarize`
- [x] Summary view — click an evidence chip → play that point · expand the original text
- [x] 35 tests added (serialization 12 · normalization 15 · metering/fallback 8)

**Side harvest** — while wiring up metering we found and fixed a bug where worker retries in
an overdraft state **charged the same usage multiple times.** On the free plan a zero balance
is the normal state, so this path is the normal path.
→ [06-billing.md](06-billing.md#idempotency)

## M5 — Sharing · Permissions · Taxonomy  ✅ Done

| Item |
|---|
| `Access.AccessLevel` — Reviewer / Contributor / Viewer |
| Visibility settings UI (`me_only` / `assignees_only` / `selected_friends` / `all_friends`) |
| `SharedLink` + `granted_role` + PIN + one-time links |
| Guest view `/share/:token` |
| Topic · Label CRUD |
| **Archive filter search** (topic · label · date range · participant · full-text) |
| Markdown export |

**Done when**: issuing a one-time link and opening it while logged out grants only the
designated role. Archived meetings are findable by topic/label.

**Progress**

- [x] **Security hardening** (prerequisite for guest links — details in [10-porting-map.md](10-porting-map.md) B8–B10)
  - [x] Client-supplied `audio_url` is no longer accepted. Presign chooses the key and records it in `storage_key`
  - [x] Worker SSRF guard — must pass `Storage.own_object_url?/1` + `max_redirects: 0`
  - [x] `audio_href` → `GET /api/sessions/:id/audio` → presigned GET 302 (Viewer gets 404)
  - [x] Archive lock — upload · presign · transcription · transcript edits
- [x] **Topic · Label CRUD** — schemas · context · REST · soft delete + detach · ordering · ownership validation
- [x] **List query hardening** — `count_meetings/2` · explicit label array types · LIKE escaping · participant filter · offset
- [x] **Archive filter search UI** — topic · label (AND/OR) · date range · participant · full-text · **URL query sync**
- [x] Taxonomy management screen (`/app/taxonomy`)
- [x] **`SharedLink`** — sha256 token hash · Bcrypt PIN · `granted_role` · one-time use · expiry · rotation
- [x] **`GuestSession`** (new) — bound to exactly one meeting. Revocation, deactivation, and expiry cut it off immediately
- [x] **Guest public API** — no meeting id in the paths. Transcription/summary/upload routes were never added
- [x] Guest view `/share/:token` + Reviewer share dialog
- [x] Markdown export (`GET /api/meetings/:id/export.md`)
- [x] **Adversarial review** — 44 findings across 5 lenses → refuted each, fixed only the real defects (below)
- [x] **Visibility settings UI** — 4 scopes · friend selection · Contributor selection · **Reviewer handover**
- [x] **"Only me" trap warning** — the server checks Contributor before visibility, so switching to "Only me" still lets Contributors see the meeting. Users believe they made it private

**Fixed via the adversarial review**

| Problem | Fix |
|---|---|
| Share tokens sat in URL paths, so Phoenix request logs kept them **in plaintext** | `VR.LogRedactor` — masks `slt_`/`gst_` ahead of the logger |
| The 5-attempt PIN lockout was read-modify-write and collapsed under concurrent requests | Increment and lockout in **one UPDATE statement** |
| Merely logging in bypassed the `guest_link_enabled` switch and could burn one-time links | The switch is independent of login state. Unauthorized accounts are treated like anonymous users |
| The account entry path discarded the request body, so PIN and name never arrived (a logged-in third party could knock 5 times and lock the link for 15 minutes) | Pass `params` through unchanged |
| `is_active: false` and shortened expiry could not cut off guests already inside | `fetch_live_guest` re-verifies link state on every request (exhaustion is the exception — documented policy) |
| `speaker_map[].account_id` leaked to guests | Keep only the name; drop the account id |
| `X-Forwarded-For` was trusted unconditionally, neutering IP lockouts | Only honored when `app.trust_proxy_headers` is explicitly enabled |
| The first gitleaks allowlist lacked `targetRules`, so **every rule was disabled** under `docs/` | Applied only to generic rules. Added `slt_`/`gst_` detection rules |

## M6 — Subscription · Credits  ✅ Done

| Item |
|---|
| Plan · PlanRevision · Subscription |
| CreditLot · CreditLedgerEntry (FIFO · append-only) |
| ServicePricing · ModelPricing + transcription/summary usage recording |
| MonthlyGrantWorker · CreditExpiryWorker |
| Admin — plans · credit grants/revocations · ledger · audit log |
| User screens — balance · usage history |
| Automatic Free plan subscription |

**Done when**: after one transcription, the ledger records the exact credits and cost.
The service keeps working even with a negative balance.

**Progress** — all ported from devkanban ([14-provenance.md](14-provenance.md#billing-policy--06-billingmd))

- [x] `Plan` · `PlanRevision` — meta/commercial-terms split, revision pinning for grandfathering
- [x] `Subscription` — one per account, period management
- [x] `CreditLot` · `CreditLedgerEntry` — append-only, `Σ delta == Σ remaining`
- [x] **FIFO consumption** — expiring-soon → indefinite → insertion order, `FOR UPDATE` locking
- [x] **Overdraft** — post-hoc metering records usage even when the balance falls short
- [x] `CreditConversionSetting` — singleton USD→credit, rounded up
- [x] `MonthlyGrantWorker` · `CreditExpiryWorker`
- [x] Automatic free plan subscription on signup + first-period credit grant
- [x] Admin billing screen (`/_admin/billing`) — conversion rate · revision issuance
- [x] 4 themes · admin account management · MFA (earlier work)
- [x] 223 tests
- [x] User billing screen (`/app/billing`) — balance · remaining lots · **usage history + calculation basis**
- [x] `charge_usage` called from the transcription/summary workers (wired in M3/M4)

## M7 — PWA · Finishing  🔨 In progress

| Item |
|---|
| manifest · service worker · install prompt |
| Push notifications (transcription/summary complete) |
| i18n cleanup for 6 languages |
| Accessibility (`aria-live`, non-color distinctions) |
| **Real-device verification** — iOS Safari / Android Chrome background recording |
| Open-source prep — README · LICENSE · CONTRIBUTING · final secret scan |

**Progress**

- [x] **PWA** — manifest · icons (192/512/maskable/apple-touch) · service worker · install banner
- [x] **Push notifications** — VAPID subscriptions · sent on transcription/summary completion · per-device subscription management
- [x] Device settings screen (`/app/settings`) — notifications · add-to-home-screen guidance
- [x] Accessibility — `aria-live` announcements for recording state · non-color distinctions (checkmarks · weight) · speaker names alongside colors
- [x] Open-source prep — README feature table · CONTRIBUTING · SECURITY · zero findings in secret scan
- [ ] **LICENSE** — left empty; choosing a license is the project owner's decision
- [ ] i18n for 6 languages (below)
- [ ] Real-device verification (not currently possible)

### What the service worker is careful about

This is a recording app — a bad cache can lose a meeting. The scope is deliberately narrow.

| Rule | Why |
|---|---|
| **Never** intercept `/api/` | Caching authenticated responses shows someone else's meeting notes even after logout |
| Never touch non-GET requests | An S3 presigned PUT that passes through the service worker breaks the signature |
| Cache-first only for hashed assets | Caching files whose names stay the same while content changes traps users on old code |
| Network-first for the shell | New deployments arrive immediately. Falls back to cache only when offline |

### Why i18n is still open

There are **488 strings across 31 files.** A mechanical migration is possible, but
the ja · es · zh_CN · zh_TW translations aren't product quality without native-speaker
review. Converting only half the strings to keys would recreate the "hardcoded strings
mixed with keys" state sisyphus was criticized for, so this stays a **separate,
do-it-all-at-once task.**

The infrastructure is ready — accounts have a `locale` field (6 languages) and
`packages/core` is framework-independent, so there's a natural place for a translation layer.

---

## Risks

| # | Risk | Impact | Response |
|---|---|---|---|
| R1 | **Recording stops in the mobile background** | Long meetings lost | Early real-device testing in M2. Keep-screen-on (Wake Lock), periodic partial saves, close the session immediately on interruption detection |
| R2 | iOS Safari MediaRecorder restrictions | Format/behavior differences | Keep the mp4/aac fallback. Real-device verification from the start |
| R3 | STT polling exceeding 30 minutes | Long audio fails | Respect the split threshold (20 minutes), make the polling cap adjustable |
| R4 | FFmpeg not installed | Every transcription over 20 minutes fails | Binary presence check at boot + admin warning banner |
| R5 | LLM output schema violations | Summary parsing fails | Enforce structured output + one retry on validation failure, then `summary_failed` |
| R6 | Speaker diarization accuracy | Manual correction burden on users | Per-segment correction UI is the key mitigation. Provide keyboard shortcuts |
| R7 | Korean full-text search quality | Weak archive search | Validate `pg_bigm`/trigram first. Consider separate indexing if insufficient |
| R8 | Duplicate credit ledger entries | Aggregation errors | `idempotency_key` unique constraint. Worker retry safety tests |

---

## Verification priorities

Verify by **uncertainty**, not by feature.

1. **Mobile real-device recording in M2** — a failure here shakes the product's premise (R1, R2)
2. **Split transcription over 20 minutes in M3** — the most complex path in the pipeline (R3, R4)
3. **Summary source jump in M4** — whether the core UX actually holds (R5)
4. The rest is mostly porting and therefore comparatively predictable
