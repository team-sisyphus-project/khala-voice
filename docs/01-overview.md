# 01. Overview

## Product

A service that records voice meetings in the browser, transcribes them with speaker
diarization, and summarizes them with AI. Supports desktop web, mobile web, and PWA.

It extracts the **Meeting Recorder** feature from the existing `autosquad/sisyphus` into a
standalone app, stripping out collaboration-platform concepts like organizations, projects,
and tasks and replacing them with an **accounts / friends / sharing** model.

## Core user flow

```
Log in → create meeting → record (pausable) → auto upload → auto transcription (diarized)
      → name the speakers → generate AI summary → click a summary item to play that utterance
      → share with friends or issue a one-time link → archive → search by topic/label
```

## Scope

### In scope

| Area | Contents |
|---|---|
| Accounts | Email + password, social login (admin ON/OFF), multi-device sessions, scheduled deletion |
| Friends | Email / link invitations, accept/decline, friends list |
| Meetings | Creation, recording, session management, state transitions, deletion, archiving |
| Transcription | Google Cloud STT v2 diarization, automatic splitting over 20 minutes |
| Speakers | Per-speaker name/account mapping, per-segment speaker correction, text editing / splitting / restore |
| Summary | Direct LLM calls, source citations (click to jump to audio) |
| Sharing | Reviewer/Contributor/Viewer roles, friend sharing, one-time guest links |
| Classification | Topics and labels, filtered archive search |
| Playback | Unified audio player, segment highlight sync |
| Export | Markdown |
| Subscriptions | Plans, subscriptions, credit ledger, usage metering (free plan only) |
| Admin | API key management, pricing management, plan management, credit adjustments, ops views |
| PWA | Install, offline upload queue, push notifications |

### Out of scope (non-goals)

- **Video conferencing** (Agora RTC / cloud recording) — a sisyphus feature we do not port
- **Payments** — only the Plan/Credit schemas exist; payment integration is a placeholder
- **MFA** — explicitly excluded
- Organizations, projects, tasks, subtasks
- AI chat, CRM (communications), digests, inbox/mentions
- Vector-DB archive, agents / MCP, widget dashboards
- SSO server (acting as an OAuth2 Provider)

## Settled decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Backend is **Phoenix (Elixir)** | Both the transcription pipeline (Oban+FFmpeg+GCS) and devkanban billing are Elixir, so porting is direct |
| D2 | Frontend is **React + TypeScript**, logic split into `packages/core` | Separating logic/UI keeps the number of UIs changeable later |
| D3 | Start with a **single route, one responsive layout** for desktop/mobile | Share links are a core feature, so there must be exactly one URL |
| D4 | Admin is **Phoenix LiveView** | Mostly forms and tables; porting the sisyphus admin is cheapest this way |
| D5 | **Drop n8n.** Implement S3 presigning and AI summary directly | Removes the external workflow dependency; prompts are version-controlled |
| D6 | Configuration resolves strictly as **DB → environment variables → none** | Prepares for open-sourcing; eliminates hardcoding at the root |
| D7 | Social login is **toggled ON/OFF in the admin UI**. Shown only when keys are in the DB and it is ON | Not an essential feature |
| D8 | Role names are unified as **Reviewer / Contributor / Viewer** (including in the Korean UI) | Removes terminology confusion |
| D9 | **Storage stays on S3** | We keep the sisyphus setup as-is for now |
| D10 | **Keep topics and labels.** Archived meeting notes must be searchable via filters | |
| D11 | Free plan is `included_credits = 0` + **overdraft allowed**. Metering is recorded precisely | So going paid is just flipping a switch |
| D12 | Guest sharing = grant access **while keeping the existing permission model intact** | No separate ownership model needed |

## Assumptions (update the docs if these change)

- **A1.** "Archive" does not mean sisyphus's vector-DB archive; it means filtering meetings
  with `status = archived` by topic, label, date range, participants, and full-text search.
- **A2.** Storage uses S3, but the GCS staging-bucket round trip required by STT stays.
  (S3 upload → server download → GCS upload → STT → GCS cleanup)
  The storage adapter is kept behind an interface so we can consolidate onto GCS later.
- **A3.** The default LLM provider is Gemini. Switchable to Anthropic / OpenAI in the admin UI.

## Terminology

| Term | Meaning |
|---|---|
| **Meeting** | A meeting. Container holding multiple RecordingSessions |
| **RecordingSession** | One recording. Goes through the upload → transcription flow independently |
| **Segment** | One utterance in the transcription result (`speaker`, `text`, `start_ms`, `end_ms`) |
| **Speaker Map** | Mapping from speaker key (`speaker_1`) to display name and account |
| **Reviewer** | Meeting owner. Full control (internal code `lv0`) |
| **Contributor** | Participant. Recording, playback, editing (internal code `lv1`) |
| **Viewer** | Read-only observer (internal code `lv2`) |
| **View Scope** | The visibility level the user picks in the UI. Roles above are computed from it |
| **Credit** | Unit of usage metering. The public-facing name is configurable (e.g. "cookies") |
| **Lot** | A granted bundle of credits. Has its own remaining balance and expiry |
| **Ledger** | Record of credit changes. Append-only |
