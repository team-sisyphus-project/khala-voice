# 15. MCP · Khala Integration

There are two directions. **Do not confuse them** — one is others reading us,
the other is us sending to others.

```
 (A) We are the MCP server     External AI ──reads──▶ KHALA VOICE archive
 (B) We are the MCP client     KHALA VOICE ──sends──▶ Khala inbox
```

---

## A. Our MCP server — letting others read the archive

Lets external services (other AIs · agents) see our archive.

### The server re-checks permissions

MCP is no exception. The rules in `docs/05-auth-sharing.md` apply **unchanged.**

| Rule | In MCP |
|---|---|
| No access means 404 | A nonexistent meeting and an unauthorized meeting get the same response |
| Viewers get no audio | Audio URLs are never included in responses |
| Reviewer-only fields | `permissions` · `owner_id` · `reviewer_id` are stripped |

This is what the existing shared view (`API.Public.ShareController.strip_internal/1`)
already does. **We use the same function** — with two copies, only one gets fixed and
information leaks.

### Tokens

An MCP client is not a person. So we issue **account-bound read-only tokens.**

- Issuance: Settings → Integrations → "Create read token"
- Storage: hash only (`sha256`). The original is shown only at issuance — same approach as share links
- Scope: **archive read-only.** No write, delete, or audio download
- Revocation: anytime. Revoked tokens get an immediate 404

### Tools

| Tool | What it does |
|---|---|
| `list_meetings` | Archive search. Topic · label · date range · query — same conditions as the on-screen filters |
| `get_meeting` | One meeting. Summary · taxonomy · participants (names only) |
| `get_transcript` | The raw transcription. Speaker names with `speaker_map` applied |

Audio is not provided. Text is enough for the substance of meeting notes, and
**a voice is itself personal data** — not something to pour out over a single token.
(For the same reason, sends to Khala include only the summary and transcription, no audio.)

---

## B. Sending to Khala

### Auth — OAuth 2.0 (PKCE)

Confirmed from the live metadata (2026-08-20):

```
authorization_endpoint   https://mcp.khala.to/oauth/authorize
token_endpoint           https://mcp.khala.to/oauth/token
registration_endpoint    https://mcp.khala.to/oauth/register
grant_types_supported    ["authorization_code"]
code_challenge_methods   ["S256", "plain"]
token_endpoint_auth      ["none"]          ← public client, no client_secret
scopes_supported         ["khala"]
resource                 https://mcp.khala.to/mcp
```

**Why we don't use plugin tokens (`/api/plugin/*`)**: those are for humanless principals
like CI and bots. Using one would make everyone send through a single service account,
and **"who sent this" disappears.** We need each user sending to their own inbox with
their own Khala account.

**The absence of a client_secret fits our rules** — this repo is going open-source and
keeps no secrets in code (`CLAUDE.md`). PKCE (S256) takes its place.
The `registration_endpoint` enables **dynamic client registration**, so there is no need
to pre-provision and hardcode a client_id either.

### Why we call from the server

Automatic delivery happens **after the summary finishes.** By then the user's browser is
closed. An Oban worker must run it, so the token must live on the server.

Tokens are stored encrypted with `Cloak` (`VR.Vault` — already in use).
The `refresh_token` is kept alongside and refreshed before expiry.

> A browser-side approach was considered — it has the advantage that the server never
> holds anyone's token, but **automatic delivery would only work while the app is open.**
> This product's automatic delivery means "it's already there after the meeting without
> you thinking about it," so the server is the right place.

### What we send

**We send the summary. We do not send audio.**

| | Content | Size |
|---|---|---|
| Body | **Summary** — one-liner · decisions · action items · open questions · meeting link | Small |
| Attachment | The **full raw transcription** (Markdown, already produced by `Meetings.Export`) | Usually tens of KB |

The recipient is a person or another AI. With the summary as the body, **they know what
the meeting was the moment they open it**, and consult the attached transcript when they
need the evidence.

**Why no audio**: a voice is itself personal data. Automatically dropping a file containing
every participant's voice into someone else's inbox is a different act from sharing meeting
notes. When needed, send a share link (`/share/:token`) instead — that path carries expiry,
PIN, and roles, and can be cut off at any time.

Attachments go via `khala_send_attachment` as inline base64 (up to 5MB, max 10).
The transcription Markdown fits — even a 3-hour meeting is a few hundred KB. If it exceeds
the limit, send the body without the attachment and note that fact on the meeting.

### Automatic delivery

**When**: after the summary is done. Sending when only the transcription is done ships it
without a summary, and then it has to be sent again once the summary lands.

**Where to**: **the inbox assigned per topic.**

```
Meeting → topic → the Khala inbox assigned to that topic
```

- If the topic has no assigned inbox, **nothing is sent.** Spilling into a default inbox
  piles weekly-meeting summaries in the wrong place
- Meetings without a topic are not sent either. Automatic delivery is the rule
  "this kind of meeting always goes there," and an unclassified meeting has no such rule
- Manual delivery (below) is always available

### Manual delivery

Pick one meeting and choose the destination **from my inbox list.**

- The list comes from `khala_list_inboxes` (`target: "mine"`)
- It is a **separate feature** from automatic delivery. Meetings with no automatic rule
  can be sent, and the same meeting can be sent again elsewhere
- Choose whether to attach the raw transcription. Summary-only is also possible

### Our inbox

When Khala is connected, we register one inbox for KHALA VOICE (`khala_register_inbox`).
This is the sender (`sender_inbox_code`) — recipients must be able to tell
"this was sent by Khala Voice."

---

## On failure

A delivery failure **never loses the meeting.** Same ordering as transcription and summary:
the meeting is already saved, and delivery is an add-on that follows.

- The worker retries (Oban)
- If it keeps failing, it is recorded on the meeting — the screen must be able to say
  "could not send to Khala"
- If the token is expired or revoked, no retries. The user must reconnect

## Config values

| Key | What |
|---|---|
| `khala.mcp_url` | Default `https://mcp.khala.to/mcp` |
| `khala.enabled` | Turning it off removes the integration from the UI entirely |

Read only via `VR.Config.fetch/2`. **No literal defaults in code**
(update `.env.example` and `docs/07-config-admin.md` together).
