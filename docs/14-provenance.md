# 14. Provenance — What Came From Where

Much of this app is taken from two existing products. **We must be able to trace which piece came from where.**

- When the original is fixed, we can judge whether this copy needs fixing too
- When asked why something looks the way it does, we can answer
- We don't have to re-excavate the original's decision rationale

## The two sources

| Notation | Repo | What we took |
|---|---|---|
| **sisyphus** | `autosquad/sisyphus` | The entire meeting-recording feature — domain · transcription pipeline · permissions |
| **devkanban** | `devkanban` (MS / ManualSquad) | The entire mobile design system · billing policy (plans · credits) |
| **khala** | `khala` | Brand (name · icons) · intro screen |

> Notation rule: leave `ported from sisyphus` / `ported from devkanban` in code comments and docs.
> Include the original file path so it can be found immediately.

---

## From sisyphus

### Domain

| This app | sisyphus original | Changes |
|---|---|---|
| `VR.Meetings.Meeting` | `lib/sisyphus/meetings/meeting.ex` | Remove `project_id` · remove `meeting_type` · remove legacy fields · `member_id`→`account_id` |
| `VR.Meetings.RecordingSession` | `lib/sisyphus/meetings/recording_session.ex` | Nearly unchanged |
| `VR.Meetings` | `lib/sisyphus/meetings.ex` | Archive (vector DB) and video-call code removed |
| `VR.Access.AccessLevel` | `lib/sisyphus/access/access_level.ex` | `project_members`→`all_friends`, organization concept removed, guest roles added |
| `VR.Sharing.SharedLink` | `lib/sisyphus/shared_links/shared_link.ex` | `granted_role` added, video-call code removed |
| `VR.Friends.FriendInvitation` | `lib/sisyphus/organizations/invitation.ex` | Role field removed → repurposed as friend invitations |
| `VR.Accounts.Account` | `lib/sisyphus/accounts/account.ex` | MFA · PasswordHistory · EmailHashHistory removed (MFA reintroduced later, admin-only) |
| `VR.System.SystemConfig` | `lib/sisyphus/system/system_config.ex` | Key list expanded · restructured around a registry |
| `VR.Vault` / `VR.Encrypted.Binary` | `lib/sisyphus/vault.ex` | Unchanged (Cloak AES-256-GCM) |
| `VR.IdGenerator` | `lib/sisyphus/id_generator.ex` | Only the prefix list adapted to this app |

### Transcription pipeline

| This app | sisyphus original | Changes |
|---|---|---|
| `VR.Transcription.GoogleSTT` | `lib/sisyphus/meetings/google_stt.ex` (997 lines) | Config source moved to `VR.Config`. **Agora-only paths removed** (HLS `.m3u8` download · MPEG-TS conversion) |
| `VR.Transcription.Audio` | `lib/sisyphus/meetings/audio_splitter.ex` | Nearly unchanged. Renamed `AudioSplitter` → `Audio` (it also measures duration and converts) |
| `VR.Workers.TranscriptionWorker` | `workers/meeting_transcription_worker.ex` | Billing call site replaced with `VR.Transcription.charge/2` |
| `VR.Workers.AudioSplitWorker` | `workers/audio_split_worker.ex` | Upload path replaced with `VR.Storage` |
| Decoding config table (`explicitDecodingConfig`) | `google_stt.ex` `get_decoding_config/1` | Only the mp2t (Agora) entry removed |
| Word→speaker grouping · adjacent merging | `google_stt.ex` `group_words_by_speaker/1` · `merge_short_segments/1` | Unchanged |
| JWT signing → access token | `google_stt.ex` `sign_jwt/2` · `exchange_jwt_for_token/1` | Unchanged |
| `VR.Workers.SummaryWorker` | `workers/meeting_summary_worker.ex` | **n8n call → direct LLM call** |

### Frontend

| This app | sisyphus original | Changes |
|---|---|---|
| `packages/core/recorder` | `assets/webapp/meeting-recorder.js` 3539–4110 | Ported to TS · **unified pause policy** · interruption detection added |
| `packages/core/upload` | `assets/shared/utils/pending-uploads.js` | **Nearly unchanged.** IndexedDB loss-prevention ordering kept |
| `packages/core/upload/uploader` | `meeting-recorder.js` 4113–4400 | Presign endpoint replaced · XHR progress added |
| Two-layer speaker structure | `meeting-recorder.js` 2416–3470 | Unchanged (`segments[].speaker` + `speaker_map`) |
| Speaker palette 10 colors × 3 shades | `meeting-recorder.js` `SPEAKER_PALETTE` | Unchanged |
| Recording UI specs | `assets/webapp/meeting-recorder.css` | Timer 48px/300 · waveform 240px · button 64px circle |
| `packages/core/domain/transcript` | `meeting-recorder.js` 2416–3470 · 5362–5960 | Ported to TS · extracted as pure functions (separated from rendering, so testable) |
| Speaker color = **fixed by order of appearance** | `meeting-recorder.js` `assignSpeakerColors` | Unchanged. Colors must survive renames so "the blue person from earlier" stays meaningful |
| Auto-merge adjacent segments | `meeting-recorder.js` `mergeAdjacentSegments` | Unchanged. Changing a speaker fuses neighbors into one block |
| Segment split = character-count ratio | `meeting-recorder.js` `splitSegmentAt` | Unchanged. Exact timestamps are unknowable, so time is apportioned proportionally |
| `original_segments` original preservation | `meeting-recorder.js` 5362–5960 | Unchanged. Editing never loses the just-transcribed values |
| Unified audio player (only one) | `meeting-recorder.js` 2960–3280 | Unchanged + webm `duration: Infinity` workaround (`fixAudioDuration`) |

### AI summary (M4)

sisyphus delegated to an n8n workflow. **This app calls the LLM directly** (user requirement: remove n8n).

| This app | Original | Changes |
|---|---|---|
| `VR.Summarize.Serializer` | sisyphus n8n `autosquad-meeting-summary.json` | Serialization convention unchanged + added delimiter stripping in speaker names |
| `VR.Summarize.Prompt` | 〃 system prompt | Unchanged. What lived in an n8n node came down into code |
| `VR.Summarize.Prompt.schema/0` | 〃 output schema | Unchanged |
| `VR.Summarize.Normalizer` | — | **New in this app.** n8n passed the model output through untouched |
| `VR.Summarize.LLM` + 3 adapters | — | 〃 (what the n8n nodes used to do) |
| `SummaryWorker` | sisyphus n8n webhook call site | Replaced with an Oban job |
| `VR.Summarize.Dev` | sisyphus `stt.dev_mode` idea | Summary edition. Pulls quotes from the actual transcription |
| Token unit-price calculation | **devkanban** `MS.Meters.UsageRecorder.price_tokens/3` | Formula and field names unchanged (`input_price_usd_per_1m` · `margin_rate`) |
| Ledger idempotency-key derivation | **devkanban** `usage_idempotency_key/2` | Unchanged — overdraft uses a fixed suffix |

### Taxonomy · search (M5)

| This app | Original | Changes |
|---|---|---|
| `VR.Taxonomy.Topic` | sisyphus `lib/sisyphus/topics/topic.ex` | Table `categories`→`topics` · `project_id`→`owner_id` · `title`+`display_label`→`name` · `description` removed · free HEX→palette keys · `sort_order`/`deleted_at` added |
| `VR.Taxonomy.Label` | sisyphus `lib/sisyphus/labels/label.ex` | Same as above. The 20-character name cap is kept from the original |
| `VR.Taxonomy.Color` | sisyphus `assets/shared/utils/color-picker-utils.js` `DEFAULT_PALETTE` | Took only the HEX values and **changed the approach** — palette keys instead of free HEX. With four themes there is no guarantee an arbitrary color reads on all four backgrounds |
| `VR.Taxonomy` | sisyphus `topics.ex` · `labels.ex` | CRUD skeleton only. **Soft delete + detach · user ordering · ownership validation are new** |
| `Meetings.filter_participant/2` | sisyphus `lib/sisyphus/archives.ex` participant filter | Organization/author concepts stripped, reduced to the three slots Reviewer / owner / Contributor |
| Archive filter UI | sisyphus archive search screen | URL query sync is **new** (sisyphus mobile had no URL routes at all — B6) |

### Visibility UI (M5)

| This app | Original | Changes |
|---|---|---|
| `packages/core/domain/permissions` | sisyphus `assets/shared/components/core-ui.js` (`VIEW_SCOPES`, `normalizeViewScope`) | `selected_members`→`selected_friends` · `project_members`→`all_friends` · storage key `memberIds`→`accountIds` · hardcoded pastel colors removed (with four themes, light-only colors don't read) |
| `VisibilityPanel` · scope selection | sisyphus `assets/webapp/meeting-recorder.js` visibility popover | **Popover → inline radios** (the four options' descriptions are the crux of the decision; collapsing them invites misconfiguration) · labels fixed to English Reviewer/Contributor/Viewer (the original used localized terms) · **"Only me" trap warning is new** · **Reviewer handover confirmation + eviction handling on permission loss is new** · optimistic updates removed |
| `FriendPicker` | sisyphus `core-ui.js` member picker | member→friend · multi-select saves **once on close** (sending a PATCH per checkbox lets the next request depart before the previous finishes, losing the last selection) |

### Sharing · guests (M5)

| This app | Original | Changes |
|---|---|---|
| `VR.Sharing.SharedLink` | sisyphus `lib/sisyphus/shared_links/shared_link.ex` | Polymorphic `resource_type`+`resource_id` → single `meeting_id` FK · `organization_id`/`project_id` removed · **`granted_role` new** · plaintext `token` → sha256 `token_hash`+`token_prefix` · plaintext `pincode` + `:rand.uniform` → Bcrypt `pin_hash` + CSPRNG (the original was not CSPRNG and its range was off, so `100000` could never occur) · blocked the changeset from casting `:id`/`:token`/`:use_count` |
| `VR.Sharing` | sisyphus `lib/sisyphus/shared_links.ex` | The check-then-increment two-query `validate_and_use_token/1` became **one conditional UPDATE statement** (the original let concurrent requests exceed `max_uses`) · use count increments when "a guest session is actually issued," not when "the link is opened" (in the original a refresh burned a one-time link) · revocation also cuts guest sessions (the original only flipped `is_active`) · video-session helpers and `resource_type` branching removed |
| `VR.Sharing.GuestSession` | **No source — new** | sisyphus had no guest sessions at all. Guest identity was a browser JS variable (`assets/webapp/video-call-guest.js`), so the server never knew "which guests are inside" |
| `VR.Sharing.ShareAttempt` | this repo's `VR.Accounts.LoginAttempt` | Same shape. Reusing `login_attempts` was avoided because the meaning of the `email` column would blur |
| `VRWeb.API.Public.ShareController` | sisyphus `lib/sisyphus_web/controllers/guest_link_controller.ex` | **Removed the meeting id from the URL** · dropped trust in `params["member_id"]` (in the original, this value bypassed both `guest_link_enabled` and the PIN at once) · fail-open checks became fail-closed · JSON instead of server-rendered HTML error pages |
| `VRWeb.API.ShareLinkController` | sisyphus `lib/sisyphus_web/controllers/shared_link_controller.ex` | lv0/lv1 → **lv0 only** · project membership → that meeting's Reviewer (in the original any member could read plaintext tokens/PINs and kill other people's links) · multiple links issued instead of reusing the active link |
| `VR.LogRedactor` | **No source — new** | Share tokens sit in URL paths and land in Phoenix request logs in plaintext; this blocks them ahead of the logger |
| `VR.Meetings.Export` | sisyphus `assets/webapp/meeting-recorder.js` `exportTranscriptMarkdown()` | Client Blob → **server rendering** (the original diverged: desktop `.md` / mobile `.txt`) · absolute wall-clock → **session-relative time** (to align clocks with the summary's `source.time_label`) · session boundary markers added · **summary included** (absent in the original) · filename sanitization + RFC 5987 |
| `VR.Meetings.Speakers` | 〃 three-tier speaker-name fallback | `member_id` → `account_id`. Shares only the fallback with `Serializer`; sanitization is separate (one side must delete, the other must escape) |

### Conventions · policies

| Item | Source | Notes |
|---|---|---|
| Transcription serialization `[session_id\|speaker\|HH:MM:SS] utterance` | sisyphus n8n `autosquad-meeting-summary.json` | Convention agreed with the prompt. Changing it breaks summary source extraction |
| `summary_data` schema | 〃 | `one_liner` · `decisions` · `action_items` · … |
| Summary prompt rules | 〃 | Extract verbatim · no abbreviation/translation · empty string when unreadable |
| S3 SigV4 presign spec | sisyphus n8n `get-upload-url.json` | Signed headers `content-disposition;content-type;host` · expiry 1800s |
| Four permission levels (lv0–lv3) | `lib/sisyphus/access/access_level.ex` | Only the names unified to Reviewer/Contributor/Viewer |
| MIME fallback chain | `meeting-recorder.js` `getSupportedAudioMimeType` | webm → mp4 (Safari) → ogg |
| 20-minute split threshold | `workers/meeting_transcription_worker.ex` | Google STT batchRecognize limit |

### Not ported (sisyphus-specific)

Organizations · projects · tasks · JustChat · communications (CRM) · digests ·
vector-DB archive · inbox/mentions · agents/MCP · Agora video calls ·
payments (LemonSqueezy/Paddle/Stripe/PayLetter) · SSO server · widget dashboard

---

## From khala

The service name is **KHALA VOICE**. The brand belongs to the khala family, so the icons
and intro came from there.

| This app | khala original | Changes |
|---|---|---|
| `backend/priv/static/images/brand/*` | `frontend/public/*` | **Unchanged** (original icons · wordmark, kept for reference) |
| `backend/priv/static/images/icon-*.png` | Composition of `frontend/public/icon-bg-*.png` | **Redrawn** — the paper plane became a **microphone**, the blue starlight became **red**. The layout (bottom-left object + top-right starlight) and black background are kept from the original |
| `apps/web/src/components/IntroScreen.tsx` | `frontend/src/components/intro/IntroScreen.tsx` | The phases (logo → exit) and once-per-session rule are kept. The PWA return splash was **not taken** (returns during recording are frequent and it gets in the way); the wordmark is text instead of an image (it must follow the theme) |
| `.vr-intro*` CSS | `.kh-intro*` in `globals.css` | Timing unchanged, colors moved to theme tokens |

---

## From devkanban

### Design system → [12-design-system.md](12-design-system.md)

On 2026-08-20, at the user's request, **the mobile design was swapped wholesale for devkanban's.**
Before that we had taken only the tokens and themes while keeping this app's own markup, but
the ask was for everything to match — button press feedback · header treatment · inputs ·
modal glassmorphism — so we went the route of **keeping the CSS pristine and conforming the
markup (class names) to it.**

Styles live in one place, `packages/ui-styles/`, and **the web app (React) and LiveView read
the same files.** Two copies would inevitably diverge — the same mistake sisyphus made by
keeping the same logic in two copies for desktop/mobile until the behavior split.

| This app | devkanban original | Changes |
|---|---|---|
| `packages/ui-styles/devkanban/tokens.css` | `mobile/src/styles/tokens.css` | **Unchanged** |
| 〃 `base.css` | `mobile/src/styles/base.css` | **Unchanged** |
| 〃 `components.css` | `mobile/src/styles/components.css` | **Unchanged** |
| 〃 `redesign.css` | `mobile/src/styles/redesign.css` | **Unchanged** |
| 〃 `media-skin.css` | `mobile/src/styles/media-skin.css` | **Unchanged** (pencil/watercolor media skin) |
| 〃 `press.css` | `mobile/src/styles/press.css` | **Unchanged** (press-feedback system) |
| 〃 `game-skin.css` | `mobile/src/styles/game-skin.css` | **Unchanged** |
| `packages/ui-styles/overrides.css` | — | **This app's own.** See "What we overrode" below |
| `apps/web/src/ui/*` | `mobile/src/components/*` | Markup as-is. `Drawer` (hamburger) · `MorphingText` not taken |
| `apps/web/src/ui/press.ts` | `mobile/src/press.ts` | **Unchanged** |
| `apps/web/src/ui/IconButton.tsx` | — | **Addition.** The original kept it inline inside TopAppBar, but actions vary per screen here, so it was extracted. Looks identical to the original |
| `apps/web/src/ui/Sheet.tsx` | `BoardSheet` in `mobile/src/screens/BoardSettingsSheet.tsx` | Also closes on Esc (used on desktop too) |
| `backend/assets/css/legacy-tokens.css` | — | **This app's own.** A bridge connecting old token names to devkanban tokens. Should shrink as screens migrate |
| DungGeunMo font | `priv/static/fonts/DungGeunMo.woff` | Unchanged (Game theme pixel font) |

**What `overrides.css` overrode** — the reasons matter

| Override | Reason |
|---|---|
| Accent from orange (hue 45) → **red** (hue 25) | This service's key color. Lightness/chroma structure kept so contrast validation need not be redone |
| `.mobile-section--card` (glass card) | devkanban puts one flow per screen, but this app stacks several blocks of different character on one screen. Same materials as the original `.mobile-pwa-card` |
| Redefine `--mobile-surface-inset` inside cards | The original inset (87%) is relative to the canvas (94%), so on a glass card (≈97%) it reads as a gray slab |
| Section gap 36px → 14px, side padding 24px → 16px | This app stacks five or six cards per screen |
| Remove top-bar spacing on top-level tab screens | With no back button, the top bar has no reason to claim space. The title sits at the very top with actions on the same line |
| Always show the title capsule on depth screens | The original hides it until scroll. This app's depth screens put no title in the body, so hiding it erases "where am I" |
| Added a `.bottom-nav a` rule | The LiveView tabs are `<a>` elements. The original CSS only targets `button` |
| Removed the chip dot (`::before`) | User request — the chips already carry color themselves |
| Extended the pencil skin to this app's boxes | `media-skin.css` targets only devkanban markup (`.mobile-row` · `.mobile-button` …). This app's new `.mobile-section--card` · `.vr-*` are names the skin doesn't know, so they stayed lone smooth rectangles in the Pencil theme. We borrowed **the same materials** (`--pc-stroke` · `--pc-ink`) and re-hooked them onto our names |
| Record-button microphone set to `FILL 1` | An outlined mic inside a red circle looks hollow with thin strokes. `opsz` is also matched to the actual render size |
| `.vr-rec-button[data-blocked]` (hatched border) · `.vr-mic-trouble*` | devkanban has no place to say "you can't press because permission is blocked." `:disabled` alone is indistinguishable from "you can't press because **the meeting ended**," so the mic-blocked state gets its own red hatching with numbered per-device unblock steps beneath it. Colors and spacing all use original tokens (`--mobile-danger` · `--mobile-space-*`) |
| Restore the icon font in the Game theme | `[data-theme="game"] *` forces the pixel font onto **every element.** devkanban wasn't affected because its icons are inline SVG, but this app uses Material Symbols (a ligature font), so icon **names printed as literal text** |

**devkanban's decision record**

- The pixel theme was rejected on 2026-08-08 (revision note in `docs/theme-medium-skin-plan.md`) —
  "too many lines · only works if layout metrics change too"
- Revived on 2026-08-17 as the Game theme (`themes/game.css` header) —
  "the Game theme changes layout metrics by design, and as a hidden theme not exposed in
  settings it is never forced on ordinary users. So the rejected pixel spec was brought in here."
- **This app exposes the Game theme in settings** (devkanban hides it) — user request

### Icons

devkanban's inline SVG registry (`mobile/src/Icon.tsx`) was brought over as-is, then
**reverted.** The names this app uses (`ios_share` · `arrow_upward` · `settings` …) were
missing from the registry, so screens showed empty circles or the literal name text.
User decision (2026-08-20): "Let's just use the Material icons."

`Icon` now draws **Material Symbols Rounded** glyphs — the same set as the LiveView side.
The class name (`mobile-icon`) is kept because devkanban CSS hooks onto it.

### Admin MFA deadlock

| This app | devkanban original | Changes |
|---|---|---|
| `AuthLive.MFAEnrollLive` + `SessionController.enroll/2` | `enroll/2` · `verify_enroll/2` in `session_controller.ex`, `session_html/enroll.html.heex` | **Same solution.** The markup is this app's, and the QR library (`eqrcode`) was not brought in — most authenticator apps support manual key entry |

**Problem**: an account for which two-factor auth is mandatory (system admin) can enter
nothing until it's enabled — and if the enable screen lives inside the admin area, it becomes
**a door that locks its own key inside.** A new admin could never get in without touching the
DB directly.

**Solution**: put the enrollment screen **inside the login flow** (`/login/mfa/enroll`).
With the password passed and no session yet, completing enrollment is what finishes login.

A hole plugged alongside it: `MFA.verify/2` returned `:ok` for accounts with
`mfa_enabled: false`. Since login unconditionally sends admins to the code screen, **an admin
who hadn't enabled MFA passed with any number** — pretending to have two-factor auth while
actually guarding with just a password.

### Billing policy → [06-billing.md](06-billing.md)

| This app | devkanban original | Changes |
|---|---|---|
| All design principles | `docs/billing-commerce-design.md` | Payments and pack-purchase sections excluded |
| `Plan` (mutable meta) | `lib/manualsquad/billing/plan.ex` | Workspace · enterprise fields removed |
| `PlanRevision` (immutable snapshot) | `billing/plan_revision.ex` | Runtime · concurrency fields removed |
| `Subscription` | `billing/subscription.ex` | `organization_id`→`account_id`, payment fields trimmed |
| `CreditLot` (FIFO consumption unit) | `billing/credit_lot.ex` | `held`-related code removed |
| `CreditLedgerEntry` (append-only) | `billing/credit_ledger_entry.ex` | Refund · chargeback sources removed |
| **FIFO consumption · `FOR UPDATE` locking** | `billing/credits.ex` `lock_available_lots/1` · `take_from_lots/5` | Holds removed |
| **Overdraft recording** | `billing/credits.ex` `consume_allow_overdraft/3` | Unchanged |
| **Per-lot idempotency_key derivation** | `key_part` in `billing/credits.ex` `ledger_option_attrs/4` | Unchanged |
| **`CreditConversionSetting`** | `billing/credit_conversion_setting.ex` | **Unchanged** — singleton USD→credit conversion |
| **Conversion formula** | `billing/credit_conversions.ex` | **Unchanged** |
| `PlanRevision.granted_credits/1` | `billing/plan_revision.ex:102` | Unchanged |
| `MonthlyGrantWorker` | `billing/monthly_grant_worker.ex` | Unchanged |
| `CreditExpiryWorker` | `billing/credit_expiry_worker.ex` | Unchanged |
| `BillingAuditLog` | `billing/billing_audit_log.ex` | Unchanged |
| `CommerceSettings` (terminology branding) | `billing/commerce_settings.ex` | Unchanged |

**devkanban's settled decisions** (`docs/billing-commerce-design.md` §2)

1. Commercial changes create a new revision; existing subscriptions are grandfathered
2. Customer-facing terminology is one global set + locale overrides
3. Payment providers are neutral (only provider + external_id columns)
4. Monthly plan grants expire at period end (no rollover); pack and admin grants are indefinite without an explicit expiry
5. Each revision carries a multi-currency price map
6. Revocation can never take a balance negative

**Not ported**: all of payments (Order/Payment/Provider/Webhook/Refund/Reconciliation) ·
auto top-up · enterprise contracts · trial conversion · sunset/scheduled changes ·
credit pack purchases · workspace runtime metering · `PlanPricingPolicy` (sale windows · previews)

---

## Where the two sources overlap

When both solved the same problem differently, which one we chose.

| Item | sisyphus | devkanban | This app's choice |
|---|---|---|---|
| **Credit conversion** | Per-service `cookie_rate` (`ServicePricing`) | Singleton USD→credit (`credit_value_usd`) | **devkanban** — derived from actual cost, so a unit-price change touches one place |
| **Rounding** | `max(round(...), minimum)` | Always `ceil` | **devkanban** — rounding up is safe for the operator, and one policy is simpler |
| **Design** | Light-only glassmorphism | 4 themes (medium × temperature) | **devkanban** — per-user theme requirement |
| **Accent** | Red `#f04452` | Orange `oklch(65% .20 45)` | **sisyphus** — the record button is red, so match the family |
| **ID scheme** | Prefixed string PK (`meet_…`) | Integer PK + `public_id` | **sisyphus** — one system, simpler |
| **Permissions** | 4 levels lv0–lv3 | — | **sisyphus** |
| **Encryption** | Cloak + `Encrypted.Binary` | — | **sisyphus** |

---

## Unique to this app (in neither source)

| Item | Why it was built new |
|---|---|
| **Friendship** (`Friendship`) | Both sources are organization/workspace based, so there is no counterpart |
| **Bootstrap admin** | The procedure to open the door right after install and close it after promoting a real user |
| **Admin lockout prevention** | Refuse demoting/deleting the last admin |
| **Admin-only MFA + dev bypass** | System admins only. Outside production, any 6-digit number passes |
| `VR.Config` three-tier resolution (DB→ENV→none) | Preparing for open-source release. sisyphus had `SystemConfig` but no registry/fallback system |
| `VR.Storage` direct presign implementation | sisyphus delegated to an n8n webhook |
| `VR.Summarize` direct LLM calls | 〃 |
| `packages/core` logic/UI split | sisyphus copied its logic twice, for desktop and mobile |
| Unified theme bundle | The old lazy-load files couldn't override the current token names, so they were removed and everything is bundled like devkanban |
| `mix vr.doctor` | With many external dependencies, one screen showing what's broken and why was needed |

---

## Defects found in the sources (fixed during the port)

Verified firsthand while reading the `sisyphus` code. Port it verbatim and they come along.
Details in [10-porting-map.md](10-porting-map.md#known-defects-to-fix-during-the-port).

| # | Defect | Original location |
|---|---|---|
| B1 | Desktop resume after pause does not work (calls to undefined functions) | `meeting-recorder.js:3772, 3795` |
| B2 | Pause means different things on desktop and mobile | `meeting-recorder.js` vs `mobile.js` |
| B3 | Language code mismatch (`zh-CN` vs `cmn-Hans-CN`) | `project-home.html` vs `meeting-recorder.js` |
| B5 | **AWS keys committed in plaintext in the repo** | 3 files under `n8n-workflows/*.json` |
| B6 | No URL routes on mobile (no deep links) | `mobile.js` overlay |

---

## Maintenance rules

1. **When code is taken from a source, record the provenance in the file's `@moduledoc`.**
   ```elixir
   @moduledoc """
   ...
   Ported from sisyphus `lib/sisyphus/meetings/google_stt.ex`.
   """
   ```
2. **Update the tables in this document at the same time.** Code comments alone don't show the full picture.
3. **Write down what differs from the original.** Whether something is "unchanged" or "what changed" is the later criterion for whether to consult the original again.
4. **Carry over the original's decision rationale too.** Once the "why" is lost, the same debate gets repeated.
