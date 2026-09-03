# 09. API

REST + SSE. All responses are JSON. Authentication via session cookie (web) or guest token (share links).

## Common conventions

| Item | Rule |
|---|---|
| Success | `200` / `201` + resource JSON |
| Validation failure | `422` + `{ "status": "error", "reason": {...} }` |
| Not authenticated | `401` |
| **Not authorized** | `404` — **we do not use 403.** A 403 reveals "the resource exists, you just can't see it" |
| **Access blocked (lv3)** | `404` — same response for the same reason as above |
| Link expired/inactive/exhausted | `410` — the three cases are not distinguished. Distinguishing them leaks the fact that the token was once valid |
| PIN mismatch | `401` |
| Too many attempts (PIN brute-force defense) | `429` |
| Role in responses | Meeting-related responses include `role: "reviewer" \| "contributor" \| "viewer"` |
| Masking | `audio_url` is never sent to a Viewer |

---

## Authentication

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/auth/register` | Email signup (invite code required depending on policy) |
| `POST` | `/api/auth/login` | Email login |
| `POST` | `/api/auth/logout` | End the current session |
| `GET` | `/api/auth/providers` | List of **enabled** social providers (for rendering buttons) |
| `GET` | `/auth/:provider` | Start OAuth — disabled providers return `404` |
| `GET` | `/auth/:provider/callback` | OAuth callback — disabled providers return `404` |
| `POST` | `/api/auth/password/reset-request` | Send reset email |
| `POST` | `/api/auth/password/reset` | Reset with token |
| `POST` | `/api/auth/confirm` | Confirm email |

## Account

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/me` | My account + subscription + credit balance |
| `PATCH` | `/api/me` | Name · language · timezone |
| `POST` | `/api/me/password` | Change password (invalidates other sessions) |
| `GET` | `/api/me/sessions` | List of logged-in devices |
| `DELETE` | `/api/me/sessions/:id` | Log out a specific device |
| `DELETE` | `/api/me/sessions` | Log out everywhere |
| `POST` | `/api/me/deletion` | Schedule account deletion |
| `DELETE` | `/api/me/deletion` | Cancel scheduled deletion |

## Friends

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/friends` | Friend list |
| `DELETE` | `/api/friends/:account_id` | Unfriend |
| `POST` | `/api/friends/:account_id/block` | Block |
| `GET` | `/api/friend-invitations` | Sent/received invitations |
| `POST` | `/api/friend-invitations` | Create invitation (`email` or link-based) |
| `DELETE` | `/api/friend-invitations/:id` | Cancel invitation |
| `GET` | `/api/friend-invitations/:token` | Look up invitation (no login required) |
| `POST` | `/api/friend-invitations/:token/accept` | Accept |
| `POST` | `/api/friend-invitations/:token/decline` | Decline |

## Meetings

| Method | Path | Permission | Description |
|---|---|---|---|
| `GET` | `/api/meetings` | — | List + `total`. See the parameter table below |
| `POST` | `/api/meetings` | — | Create (creator becomes Reviewer) |
| `GET` | `/api/meetings/:id` | Viewer+ | Detail (includes sessions) |
| `PATCH` | `/api/meetings/:id` | Contributor+ | Title · description · topic · labels · start date |
| `GET` | `/api/meetings/:id/taxonomy` | Contributor+ | Taxonomy attachable to this meeting (**the meeting owner's**) |
| `POST` | `/api/meetings/:id/summarize` | Contributor+ | Generate/regenerate summary. Only enqueues and responds 202 immediately |
| `PATCH` | `/api/meetings/:id/status` | Reviewer(archive) / Contributor+ | Status transition |
| `PATCH` | `/api/meetings/:id/permissions` | Reviewer | Visibility · Reviewer · Contributors |
| `DELETE` | `/api/meetings/:id` | Reviewer | Soft delete |
| `POST` | `/api/meetings/:id/archive` | Reviewer | Archive |
| `GET` | `/api/meetings/:id/export.md` | Viewer+ | Markdown export |

## Recording sessions

| Method | Path | Permission | Description |
|---|---|---|---|
| `POST` | `/api/meetings/:id/sessions` | Contributor+ | Create session. `{started_at_unix, metadata:{language}}` |
| `POST` | `/api/sessions/:id/upload` | Contributor+ | Register upload. `{duration_seconds, file_size_bytes, mime_type}` |
| `GET` | `/api/sessions/:id/audio` | Contributor+ | 302 to a signed audio URL. **Viewer gets 404** |
| `POST` | `/api/sessions/:id/transcribe` | Contributor+ | Enqueue transcription (consumes credits). Calling it again on an already-transcribed session re-transcribes |
| `PATCH` | `/api/sessions/:id/speakers` | Contributor+ | `speaker_map` or `transcript` or both |
| `DELETE` | `/api/sessions/:id` | Reviewer | Delete session |

### List filters

| Parameter | Values | Notes |
|---|---|---|
| `status` | `active` · `completed` · `archived` · `all` | If empty, **archived meetings are hidden** |
| `topic_id` | Topic id | |
| `label_ids` | Comma-separated or array | |
| `label_mode` | `and` (default) · `or` | Unknown values narrow to `and` — leaning toward widening quietly defangs the filter |
| `participant_id` | Account id | Meetings the account joined as Reviewer, owner, or Contributor |
| `from` · `to` | ISO8601 | Based on `started_at` |
| `q` | String | Title · description · summary. `%` and `_` are escaped |
| `order` | `archived_desc` | If empty, `started_at` descending |
| `limit` · `offset` | Integer | Default 50 |

The `total` in the response is **the full count matching the filter** (not the count on this page).
The list and the count use the same predicate — copy-pasting it guarantees drift.

Meeting responses include `topic` and `labels` fully expanded with names and colors.
Hiding taxonomy names from someone who can already read the meeting's full text is not a defense.

### Taxonomy (topics · labels)

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/topics` | My topics + `meeting_count` |
| `POST` | `/api/topics` | `{name, color?}` → 201 |
| `PATCH` | `/api/topics/reorder` | `{ids:[...]}` — the **complete list** |
| `PATCH` | `/api/topics/:id` | `{name?, color?}` |
| `DELETE` | `/api/topics/:id` | `{status, detached_meetings}` |
| `GET` `POST` `PATCH` `DELETE` | `/api/labels…` | Same as above (no reorder) |

- Colors are **10 palette keys** (`red` … `gray`). Free-form HEX is not accepted — with four themes, arbitrary colors won't stay legible on every background
- **Someone else's taxonomy and a nonexistent taxonomy both return 404.** A 403 would reveal that the id exists
- Deletion is a soft delete that also **immediately detaches the taxonomy from meetings using it.** Leaving dangling references would make those meetings unreachable by any filter
- Reordering takes **the entire list at once.** A partial list returns `422` and changes nothing

### Audio URLs are never sent down

`recording_key/4` is **fully determined** by `meeting_id`, `session_id`, `started_at_unix`, and the extension.
Anyone who can view the meeting receives all of these values in responses. So merely omitting the
`audio_url` field does not mask anything from a Viewer — they could assemble the key by hand.

Contributor and above get only `audio_href` (= `GET /api/sessions/:id/audio`).
That endpoint re-checks the permission and **302s to a signed URL**.
Signature expiry is 3× the recording length (min 15 minutes · max 6 hours) — long enough that
Range requests during playback don't get cut off by expiry, short enough that a leaked link
does not live forever.

**The bucket must be private.** With a public bucket, all of the defenses above are meaningless.

### The server decides the upload destination

`POST /api/uploads/presign` chooses the key and records it on the session; `upload` accepts no address.
If the client-supplied address were stored, the transcription worker would GET it verbatim,
turning it into a private-network request (SSRF).

- Requesting presign again for a session that already finished uploading returns `422 already_uploaded` — prevents overwriting the same key
- Upload · transcription · transcript edits on an archived meeting return `422 meeting_archived`

**All transcript edits go through the single `PATCH .../speakers` endpoint.**
Renaming a speaker, changing a segment's speaker, editing text, splitting, and restoring the
original all reduce to "send the whole corrected transcript."
Separate per-segment endpoints would leave partial edit states on the server.

Restoring the original uses the same path. The original lives in `transcript.original_segments`,
and undo simply means the client sends it back as `segments`.

### Speaker update payload

```jsonc
// Change a speaker chip — applies to every utterance by that speaker
{ "speaker_map": { "speaker_1": { "name": "Jane Doe", "account_id": "acct_xxx" } } }

// Change one segment's speaker — that single line only
{ "transcript": { "segments": [ /* full array with the changed speaker */ ] } }
```

## Summary

| Method | Path | Permission | Description |
|---|---|---|---|
| `POST` | `/api/meetings/:id/summary` | Contributor+ | Generate summary (when none exists) |
| `POST` | `/api/meetings/:id/summary/retry` | Contributor+ | Re-summarize (forced) |

The response is an immediate `202`; completion is announced via SSE.

## Uploads

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/uploads/presign` | `{meeting_id, session_id, file_name, content_type}` → `{upload_url, download_url, key, expires_in}` |

## Taxonomy

| Method | Path | Description |
|---|---|---|
| `GET` `POST` | `/api/topics` | List · create |
| `PATCH` `DELETE` | `/api/topics/:id` | Update · delete |
| `GET` `POST` | `/api/labels` | List · create |
| `PATCH` `DELETE` | `/api/labels/:id` | Update · delete |

## Archive search

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/archive` | `?q=&topic_id=&label_ids[]=&label_mode=and\|or&from=&to=&participant_id=&language=&cursor=` |

Responses include matching snippets:
```jsonc
{ "meetings": [ { "id": "meet_x", "title": "...",
    "matches": [ { "session_id": "mrss_a", "time_label": "00:12:34",
                   "snippet": "…let's go with the voice recording deployment…" } ] } ],
  "next_cursor": "..." }
```

## Sharing

| Method | Path | Permission | Description |
|---|---|---|---|
| `GET` | `/api/meetings/:id/share-links` | Reviewer | List of links. **No plaintext tokens or PINs** |
| `POST` | `/api/meetings/:id/share-links` | Reviewer | Issue. `{granted_role, max_uses?, expires_at?, require_name?, require_email?, with_pincode?}` → `201` + `url` · `pincode` |
| `PATCH` | `/api/share-links/:id` | Reviewer | `{is_active?, max_uses?, expires_at?, require_name?, require_email?}` |
| `POST` | `/api/share-links/:id/rotate` | Reviewer | Reissue token → `url` |
| `POST` | `/api/share-links/:id/pincode` | Reviewer | `{enabled: bool}` → `pincode` (only when enabling) |
| `DELETE` | `/api/share-links/:id` | Reviewer | Revoke → `204`. **Guests currently inside are disconnected too** |

### Plaintext goes out exactly once

`url` and `pincode` appear **only in the issue, rotate, and PIN-enable responses**.
The DB stores only a sha256 hash (token) and a Bcrypt hash (PIN), so even the server does not
know the originals. If lost, the only recourse is reissuing via `rotate`.

`granted_role` **cannot be changed after issuance.** Upgrading a distributed `viewer` link to
`contributor` would retroactively elevate everyone who received that link. To change it,
revoke and reissue.

### Guests (no authentication required)

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/public/share/:token` | Requirements only. **Not even the meeting title is revealed** |
| `POST` | `/api/public/share/:token/enter` | `{display_name?, email?, pincode?}` → `guest_token`, increments `use_count` |
| `GET` | `/api/public/guest/meeting` | Fetch the meeting. **No meeting id in the path** |
| `GET` | `/api/public/guest/sessions/:id/audio` | 302 to signed audio. Contributor guests only |
| `DELETE` | `/api/public/guest/session` | Guest leaves voluntarily → `204` |

Guest credentials are sent via the `X-Guest-Token` header. Cookies are not used because
the `:api` pipeline has no CSRF defense, and a cookie is domain-wide, which conflicts with
the "one meeting only" constraint.

### The session determines which meeting a guest sees

There is **no meeting id** in the `/api/public/guest/*` paths. The `meeting_id` is baked into
the guest session row and the server uses only that. There is simply no way for a request
to point at a different meeting.

### What guests never receive

- `owner_id` · `reviewer_id` · `contributor_ids` · `permissions` — the participant list
- `speaker_map[].account_id` — **the field most likely to leak alongside the transcription**
- `last_summary_error` — raw internal exception text
- `total_credits_charged` · `credits_charged` — the meeting owner's billing details

### What guests cannot reach

Transcription · summary · upload · presign routes are **not placed in the guest scope.**
A single link must not become a power of attorney over the meeting owner's credits.

If a logged-in account enters through a link, **the account's permission takes precedence.**

## Subscription · credits

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/billing/subscription` | Current subscription + plan |
| `GET` | `/api/billing/credits` | Balance + per-bundle expiry |
| `GET` | `/api/billing/ledger` | Usage history (`?cursor=`) |
| `GET` | `/api/billing/plans` | Public plan list |

## SSE

```
GET /api/sse/meetings/:id
```

| Event | Payload |
|---|---|
| `session_status_changed` | `{meeting_id, session_id, status, changed_by_id}` |
| `session_transcription_failed` | `{meeting_id, session_id, error_message}` |
| `summary_completed` | `{meeting_id}` |
| `summary_failed` | `{meeting_id, error}` |

Clients ignore events whose `changed_by_id` is themselves, and hold off on refreshing for a
short window right after a local edit so the edit is not overwritten.
