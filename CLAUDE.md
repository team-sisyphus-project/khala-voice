# KHALA VOICE — Working Guidelines

## What this repo is

A meeting recording, diarized transcription, and AI summary service. Desktop/mobile
web plus PWA. It extracts the Meeting Recorder from `autosquad/sisyphus` as a
standalone app and combines it with an account/friend/sharing system and the
plan/credit model from `devkanban`.
The mobile design system comes from `devkanban`; the brand (name, icon, intro)
comes from `khala`.

The design lives in [`docs/`](docs/README.md). **Read the relevant doc before
writing code.**

| Task | Read first |
|---|---|
| Schema, migrations | `docs/03-domain-model.md` |
| Recording, upload, transcription, summary | `docs/04-pipeline.md` |
| Login, permissions, sharing | `docs/05-auth-sharing.md` |
| Credits, plans | `docs/06-billing.md` |
| Config values, API keys, admin | `docs/07-config-admin.md` |
| Routing, frontend structure, navigation, design system | `docs/08-frontend.md` |
| Porting from sisyphus/devkanban | `docs/10-porting-map.md` |

## Hard rules

### 1. No secrets in code

This repo is published as open source.

- Never put API keys, tokens, passwords, or credentials in code, config, seeds,
  tests, or docs
- Read configuration values **only** through `VR.Config.fetch/2`.
  Never call `System.get_env` directly from individual modules
- `VR.Config` resolves in the order `DB → environment variable → nil`.
  **No literal defaults**
- When you add a config value, update `.env.example` and `docs/07-config-admin.md` together
- Never write a key the user pasted into chat to a file. Point them to the admin
  screen or `.env` instead

### 2. Role names are Reviewer / Contributor / Viewer

Use these English names as-is throughout the UI; do not translate or rename them.
The internal code values are `lv0` / `lv1` / `lv2` / `lv3` (no access).

### 3. No access means 404

Respond to unauthorized resources with `404`, not `403`. Do not reveal existence.

### 3-1. Styles live in `packages/ui-styles` and nowhere else

The web app (React) and LiveView read **the same files**. Do not make copies.

- `packages/ui-styles/devkanban/` **must stay identical to the upstream original.** Do not touch it
- All adjustments for this app go in `overrides.css`, with **why the override exists**
  recorded in `docs/14-provenance.md`
- The class names in the markup are the contract (`mobile-button`, `mobile-section`,
  `bottom-nav`, …). Rename one and both screens break together

### 4. Business logic lives in `packages/core`

Do not add React dependencies to `packages/core`.
The recording engine, upload queue, domain transforms, and permission checks
stay separate from the UI. sisyphus kept two copies of this logic (desktop and
mobile), and their behavior drifted apart.

### 5. The server has the final say

Disabling buttons on the frontend is a convenience, nothing more. Every mutating
API recomputes the caller's role on the server.

### 6. Imported code keeps its provenance

Record everything ported from sisyphus / devkanban in **both** places:

1. The source path in the module's `@moduledoc` (or a comment at the top of the file)
   ```elixir
   @moduledoc """
   ...
   **Source: sisyphus** `lib/sisyphus/meetings/google_stt.ex` — nearly verbatim.
   """
   ```
2. The table in [`docs/14-provenance.md`](docs/14-provenance.md)

**Always note whether it was taken "as-is" or "what was changed."** That is the
basis for deciding whether a fix upstream needs to be mirrored here.
Carry over the original's decision rationale too — lose it, and the same debate
gets repeated.

## When porting

When bringing code over from sisyphus, follow the mapping table in
`docs/10-porting-map.md` and fix the **known defects (B1–B7)** listed in the same
doc as you go. Port it verbatim and you port the bugs too.

Do not touch, in particular:
- `GoogleSTT` — the whole GCS round trip (polling, result parsing, cleanup), hardened in production
- The IndexedDB upload queue — the store → upload → delete-on-success order is what prevents data loss
- The two-layer speaker structure — do not merge `segments[].speaker` and `speaker_map`
- The source-extraction rules in the summary prompt — click-summary-to-jump-audio depends on them

## Development environment

- FFmpeg (`ffmpeg`, `ffprobe`) required
- To develop without GCP credentials, set `STT_DEV_MODE=true`
- Without `CLOAK_KEY` the app refuses to boot (by design)
