# KHALA VOICE

Record meetings in the browser, transcribe them with speaker diarization, and summarize them with AI.
Supports desktop web, mobile web, and PWA.

```
Record → Auto upload → Diarized transcription → AI summary → Friend/link sharing → Archive search
```

## Features

| | |
|---|---|
| **Recording** | Straight from the browser. Pause/resume, screen wake lock, interruption detection. When offline, audio queues up in IndexedDB and uploads automatically |
| **Transcription** | Google Cloud STT v2 (Chirp) with speaker diarization. Recordings over 20 minutes are split automatically |
| **Editing** | Speaker naming and friend linking, per-utterance speaker correction, text edits, segment splitting, restore to original |
| **Summary** | Choose Gemini, Claude, or GPT. **Tap a summary item to play back the moment it was said** |
| **Sharing** | Four friend-visibility levels plus one-time links (PIN, expiry, role assignment) |
| **Organization** | Search the archive by topic and label. Filters live in the URL, so they can be shared as-is |
| **Credits** | Plan grants plus usage metering. Shows what was spent on what, with the receipts to back it up |
| **PWA** | Home-screen install, push notifications when transcription and summary complete |

The UI has four tabs: **Meeting** (record right away), **Archive** (meeting list and search), **Friends**, and **Settings**.

## Documentation

Design docs live in [`docs/`](docs/README.md). Start with [docs/01-overview.md](docs/01-overview.md).

## Stack

Phoenix (Elixir) · PostgreSQL · Oban · React + TypeScript · AWS S3 ·
Google Cloud Speech-to-Text v2 · LLM (Gemini / Anthropic / OpenAI)

## Security principles

**This repository is published as open source. No credentials of any kind may enter the code.**

- All configuration resolves strictly in the order `DB → environment variable → absent` ([docs/07](docs/07-config-admin.md))
- No literal default values in code. If a value is missing, the feature turns off
- Secrets stored in the DB are encrypted with Cloak (AES-256-GCM)
- `gitleaks` blocks commits in the pre-commit hook and in CI

Before contributing, copy `.env.example` to `.env` — and **never commit `.env`.**

## Development

```bash
brew install ffmpeg gitleaks   # macOS. On Linux: apt-get install ffmpeg
./scripts/install-hooks.sh     # secret-blocking commit hook

cp .env.example .env           # fill in the values; .env is never committed
openssl rand -base64 32        # generate CLOAK_KEY

cd backend
mix setup
mix vr.doctor                  # environment and config check
mix phx.server
```

**FFmpeg only needs manual installation locally.** The deploy image (`backend/Dockerfile`)
and CI already include it, and an image missing FFmpeg fails the build.

To develop without GCP credentials, set `STT_DEV_MODE=true` to receive mock transcription results.

## System admin

### Creating the initial account

**There is no default username or default password in the code.** If every deployment
shared the same values, that alone would be an attack target. The first account is
created once, with values you choose yourself.

```bash
cd backend

# Choose the username (email) and password yourself
BOOTSTRAP_ADMIN_EMAIL=admin@example.com \
BOOTSTRAP_ADMIN_PASSWORD='a-strong-password-you-chose' \
  mix run priv/repo/seeds.exs
```

If you omit the password, **a random one is generated and printed to the screen once.**
Write it down at that moment — only the hash is stored in the DB, so it cannot be viewed again.

```bash
BOOTSTRAP_ADMIN_EMAIL=admin@example.com mix run priv/repo/seeds.exs
# → Initial admin account created
#   Email: admin@example.com
#   Password: xxxxxxxxxxxx      ← visible only on this screen
```

If at least one admin already exists, this command does nothing.

To promote or demote an existing account:

```bash
mix vr.make_admin you@example.com
mix vr.make_admin you@example.com --revoke
```

**Admins cannot promote themselves from the UI.** Even if the admin screen were
compromised, it must not lead to privilege escalation.

### How to get in

`/_admin` is reachable **only by typing the address directly.** There is no link to it
anywhere in the app — regular users should never learn such a screen exists.
Unauthorized requests get a **404**, not a 403.

### Two-factor authentication is mandatory

An admin account **must have two-factor authentication (TOTP) enabled to enter `/_admin`.**
Accessing it without 2FA redirects to the settings screen.
If a single admin account is compromised, the whole system's configuration and API keys
go with it.

Regular users are not required to use 2FA.

> In development and staging (`MIX_ENV != :prod`), **any 6-digit number passes.**
> This lets you inspect the screens without an authenticator app, and the bypass is
> **baked in at compile time** — it cannot be enabled in production builds even via
> environment variables.

### Delete the bootstrap account

After creating a real user account and promoting it to admin, delete the initial
account. The goal is one fewer way in.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md). For security issues, follow
[SECURITY.md](SECURITY.md) and report them **privately**.

## Pre-production checklist

- **Keep the S3 bucket private** — storage paths are deterministic, so a public bucket makes access control meaningless
- Store `CLOAK_KEY` somewhere separate from the DB credentials
- Set `APP_TRUST_PROXY_HEADERS=true` only when behind a proxy
- Enable admin MFA and delete the bootstrap account

See [SECURITY.md](SECURITY.md) and
[docs/00-setup-checklist.md](docs/00-setup-checklist.md) for details.

## License

Not yet decided. Until it is, all rights are reserved.
