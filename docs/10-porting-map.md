# 10. Porting Map

> A file-by-file mapping table. For **the full picture of what came from where**,
> see [14-provenance.md](14-provenance.md).

What to bring from where, what to build new, and what to drop.

## sisyphus → voice-recording

### Backend

| sisyphus | New | Changes |
|---|---|---|
| `lib/sisyphus/meetings/meeting.ex` | `vr/meetings/meeting.ex` | Remove `project_id`, remove `meeting_type`, remove legacy fields, `member_id`→`account_id` |
| `lib/sisyphus/meetings/recording_session.ex` | `vr/meetings/recording_session.ex` | Nearly unchanged |
| `lib/sisyphus/meetings.ex` | `vr/meetings.ex` | Remove archive/vector-DB/video-call code |
| `lib/sisyphus/meetings/google_stt.ex` (997 lines) | `vr/transcription/google_stt.ex` | **Nearly unchanged.** Only the config source moves to `VR.Config` |
| `lib/sisyphus/meetings/audio_splitter.ex` | `vr/transcription/audio_splitter.ex` | Unchanged |
| `workers/meeting_transcription_worker.ex` | `vr/workers/transcription_worker.ex` | Only the billing call site replaced |
| `workers/audio_split_worker.ex` | `vr/workers/audio_split_worker.ex` | Only the upload path replaced |
| `workers/meeting_summary_worker.ex` | `vr/workers/summary_worker.ex` | **n8n call → direct LLM call** |
| `lib/sisyphus/access/access_level.ex` | `vr/access/access_level.ex` | `project_members`→`all_friends`, organization concept removed |
| `lib/sisyphus/shared_links/*` | `vr/sharing/*` | Add `granted_role`, remove video-call code |
| `lib/sisyphus/accounts/*` | `vr/accounts/*` | Remove MFA · PasswordHistory · EmailHashHistory |
| `lib/sisyphus/system/system_config*.ex` | `vr/config/*` | Expanded key list |
| `lib/sisyphus/vault.ex` + `encrypted/binary.ex` | `vr/vault.ex` | Unchanged |
| `lib/sisyphus/billing/service_pricing.ex` | `vr/billing/service_pricing.ex` | Unchanged |
| `lib/sisyphus/billing/model_pricing.ex` | `vr/billing/model_pricing.ex` | Unchanged |
| `controllers/meeting_controller.ex` | `vr_web/controllers/meeting_controller.ex` | Organization/project permission checks → friend/sharing checks |
| `live/admin/billing_service_pricing_live.ex` | `vr_web/live/admin/...` | Unchanged |
| `live/admin/billing_model_pricing_live.ex` | `vr_web/live/admin/...` | Unchanged |
| `lib/sisyphus/organizations/invitation.ex` | `vr/friends/friend_invitation.ex` | Role field removed, repurposed as friend invitations |
| `n8n_upload/upload_url_v2.ex` | `vr/storage/s3.ex` | **n8n webhook → direct ExAws presign implementation** |

**Dropped**: organizations · projects · tasks · JustChat · communications (CRM) · digests ·
archive (vector DB) · inbox/mentions · agents/MCP · the entire Agora video-call stack ·
payments (LemonSqueezy/Paddle/Stripe/PayLetter) · SSO server · MFA

### Frontend

| sisyphus | New | Changes |
|---|---|---|
| `meeting-recorder.js` recording section (3539–4110) | `packages/core/recorder/` | Ported to TS. **Unified pause policy** |
| `meeting-recorder.js` upload section (4113–4400) | `packages/core/upload/` | Presign endpoint replaced |
| `shared/utils/pending-uploads.js` | `packages/core/upload/queue.ts` | **Nearly unchanged.** IndexedDB logic kept |
| `meeting-recorder.js` speaker/transcription sections (2416–3470, 5362–5960) | `packages/core/domain/` + `apps/web/` | Logic/render split |
| `meeting-recorder.js` summary section (1678–2290) | Same | `source` jump logic kept |
| `meeting-recorder.js` player (2960–3280) | `packages/core/` + UI | webm duration correction kept |
| `project-home.html` 1287–1920 | `apps/web/routes/meetings/` | Rewritten as React components |
| `meeting-recorder.css` (3,941 lines) | `apps/web/` styles | Dependency on `styles.css` (872KB) removed. Only what's needed |
| `mobile.js` meetings section | **Deleted** | Replaced by reusing `packages/core` |
| `webapp/s3-upload.js` | `packages/core/upload/presign.ts` | Trimmed down |

**Dropped**: `CoreUI`, `JustChatCore/UI`, `CookieDisplay`, `MeetingVideo`,
`ToolConfig`, the widget system, `MeetingRecorderWidget.js`

---

## devkanban → voice-recording

| devkanban | New | Changes |
|---|---|---|
| `billing/plan.ex` | `vr/billing/plan.ex` | Workspace/enterprise fields removed |
| `billing/plan_revision.ex` | `vr/billing/plan_revision.ex` | Runtime/concurrency fields removed |
| `billing/subscription.ex` | `vr/billing/subscription.ex` | `organization_id`→`account_id`, payment fields trimmed |
| `billing/credit_lot.ex` | `vr/billing/credit_lot.ex` | `held`-related code removed |
| `billing/credit_ledger_entry.ex` | `vr/billing/credit_ledger_entry.ex` | Refund/chargeback sources removed |
| `billing/credits.ex` | `vr/billing/credits.ex` | FIFO consumption logic unchanged |
| `billing/monthly_grant_worker.ex` | `vr/workers/monthly_grant_worker.ex` | Unchanged |
| `billing/credit_expiry_worker.ex` | `vr/workers/credit_expiry_worker.ex` | Unchanged |
| `billing/billing_audit_log.ex` | `vr/billing/billing_audit_log.ex` | Unchanged |
| `billing/commerce_settings.ex` | `vr/billing/commerce_settings.ex` | Unchanged |
| `live/admin/commerce_plans_live.ex` | `vr_web/live/admin/plans_live.ex` | Trimmed down |
| `docs/billing-commerce-design.md` | [06-billing.md](06-billing.md) | Incorporated as a summary |

**Not ported**: all of payments (Order/Payment/Provider/Webhook/Refund/Reconciliation),
auto top-up, enterprise contracts, trial conversion, sunset/scheduled changes, credit packs,
workspace runtime metering

---

## n8n workflows → direct implementation

| n8n | New | Status |
|---|---|---|
| `get-upload-url` (v2) | `vr/storage/s3.ex` | ✅ Full SigV4 presign logic captured. Replaced with `ExAws.S3.presigned_url/5` |
| `autosquad-meeting-summary` | `vr/summarize/` | ✅ Prompt · output schema · parameters fully captured |
| `estimate_token_and_callback` | Not needed | Token usage is taken directly from the LLM response and recorded in the ledger |

### Presign porting notes

| Item | Value |
|---|---|
| Signature | AWS Signature V4 query string |
| Method / payload | `PUT` / `UNSIGNED-PAYLOAD` |
| Signed headers | `content-disposition;content-type;host` |
| Expiry | 1800 seconds |
| Download | Separate CDN domain |

> The n8n workflow implemented SHA256/HMAC by hand in pure JS, but
> `ExAws` handles this in Elixir, so **that part is not ported.**

### Summary porting notes

- Serialization convention `[<session_id>|<speaker>|<HH:MM:SS>] utterance` is **kept**
- Label parsing rules (extract verbatim, no abbreviation or translation, empty string when unreadable, no fabrication) are **kept**
- Output schema is **kept** → existing `summary_data` consumer code works as-is
- `temperature 0.2`, `maxOutputTokens 16384` are **kept**
- The prompt lives as a version-controlled file in the repo (an improvement over n8n)

---

## Known defects (to fix during the port)

Problems actually confirmed while reading the sisyphus code. Port the code verbatim and they come along.

| # | Problem | Evidence | Action |
|---|---|---|---|
| B1 | **Desktop resume after pause does not work** | `setupNewMediaRecorder()` calls the undefined `getSupportedMimeType()` (:3772) and `startWaveform()` (:3795). The actual definitions are `getSupportedAudioMimeType()` and `drawWaveform()`. The deployed build (`priv/static`) is identical | Resolved by unifying the pause policy around `pause()`/`resume()` |
| B2 | **Pause means different things on desktop and mobile** | Desktop = splits the session, mobile = keeps one session | Single implementation in `packages/core` |
| B3 | **Language code mismatch** | Desktop HTML `<option>` uses `zh-CN`/`zh-TW` while the JS `LOCALE_MAP` uses `cmn-Hans-CN`/`cmn-Hant-TW`. Mobile correctly uses `cmn-*` | Constants managed in one place |
| B4 | **Docs disagree with the code** | `docs/MEETING_RECORDER.md` references a nonexistent `meeting-recorder.html` and lists the statuses as `recording/completed` when they are actually `active/completed/archived` | Superseded by this document set |
| B5 | **AWS keys committed in plaintext in the repo** | `n8n-workflows/misc/get-upload-url.json` and 2 other files | New repo blocks this with gitleaks. **The sisyphus keys need rotation** |
| B6 | **No URL routes on mobile** | Overlay + internal state. No deep links or back button | Solved by the unified route scheme |
| B7 | **Hardcoded i18n mixed in** | Korean literals mixed with `getI18nString(key, fallback)` | Everything converted to keys |
| B8 | **The server trusts the client-supplied audio URL verbatim** | The early implementation of this app carried the sisyphus flow over as-is. `upload_changeset` stored `audio_url` without validation, and the transcription/split workers followed it with `Req.get(url, max_redirects: 5)` = **SSRF** (an authenticated user could point the server at private networks or metadata endpoints) | Presign chooses the key and records it in `recording_sessions.storage_key`; `audio_url` is server-generated. Workers fetch only addresses passing `Storage.own_object_url?/1`, with `max_redirects: 0` |
| B9 | **Viewer audio masking is toothless** | `recording_key/4` is fully determined by `meeting_id` · `session_id` · `started_at_unix` · extension, all of which appear in Viewer responses, and `public_url/1` is unsigned. Deleting the field still lets anyone assemble the key and fetch the original | `audio_href` → `GET /api/sessions/:id/audio` → permission re-check, then **presigned GET 302**. Assumes a private bucket |
| B11 | **Guest join trusted a client-supplied `member_id`** | `guest_link_controller.ex` skipped **both** the `guest_link_enabled` check and the PIN check based on the mere presence of `params["member_id"]`. The route sits in the sessionless `:public_api` pipeline, so the value could not be verified at all | Request bodies are never used for identity. The meeting a guest sees is determined by the server-side guest session |
| B12 | **Guest chat ignored link validity** | `list_messages`/`create_message` filtered only on `deleted_at`, so expired, inactive, and exhausted links could still read and write | Every guest path passes through the single `guest_authorize/2` gate |
| B13 | **`use_count` was non-atomic and mistimed** | Check followed by a separate increment query → concurrent requests exceed `max_uses`. It also incremented on every join, so a refresh burned a one-time link | One conditional UPDATE statement. Increments only when a guest session is actually issued |
| B14 | **PIN generation was not CSPRNG and the range was wrong** | `:rand.uniform(899_999) + 100_000` — predictable, and `100000` can never occur. Stored in a plaintext column and carried in the URL as a `?pin=` query string, leaking into browser history, referrers, and access logs | CSPRNG + uniform distribution, Bcrypt storage, never placed in URLs |
| B10 | **Archiving was not a lock** | `ensure_active` guarded only session creation, so lv1 users could keep editing transcripts and speakers on archived meetings | Added `ensure_mutable/1` to upload · presign · transcription · transcript edits (`422 meeting_archived`) |

---

## Porting cautions

1. **Do not touch the STT client.** The GCS round-trip, polling, result parsing, and
   temp-file cleanup are battle-tested code. Change only the config source; move the logic as-is.
2. **Keep the IndexedDB upload queue as-is too.** The loss-prevention ordering
   (store → upload → remove on success) is the essence and is already proven.
3. **Do not simplify the two-layer speaker structure.** Merging `segments[].speaker` and
   `speaker_map` is tempting, but per-segment correction and per-speaker mapping are
   different operations.
4. **Do not loosen the summary `source` convention.** Click-a-summary-item → audio jump is
   this product's core UX, and it depends entirely on the prompt's verbatim-extraction rules.
