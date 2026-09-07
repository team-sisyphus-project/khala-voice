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

Prerequisites: **Elixir 1.15+ (with OTP), Node.js 20+, PostgreSQL, FFmpeg.**

```bash
brew install ffmpeg gitleaks   # macOS. On Linux: apt-get install ffmpeg
./scripts/install-hooks.sh     # secret-blocking commit hook

cp .env.example .env           # fill in the values; .env is never committed
openssl rand -base64 32        # generate CLOAK_KEY
```

The minimal `.env` for a first boot is `CLOAK_KEY` (the app refuses to start
without it) plus `DATABASE_URL` — the latter only if your PostgreSQL differs
from the dev default `postgres:postgres@localhost/vr_dev`.

### From clean checkout to running app

The full verified sequence, in order. **Every step is safe to repeat.**

```bash
# 1. Backend: deps + database create/migrate/seed + LiveView assets
cd backend
mix setup
mix vr.doctor                  # environment and config check

# 2. React web app — mix setup does NOT build this
cd ../apps/web
npm install
npm run build                  # outputs to backend/priv/static/app/

# 3. Bootstrap admin account (see "Creating the initial account" below)
cd ../../backend
BOOTSTRAP_ADMIN_EMAIL=admin@example.com mix run priv/repo/seeds.exs

# 4. Start the server
PORT=4000 mix phx.server       # PORT optional; defaults to 4000
```

Smoke check — an anonymous visit to `/` redirects to the login screen,
which answers 200:

```bash
curl -L http://localhost:4000/   # → 302 → /go/meetings → 302 → /login → 200
```

**The React build step (2) is not optional.** `mix setup` builds only the
LiveView assets; `backend/priv/static/app/` is gitignored, so on a clean
checkout everything under `/app/` stays empty until `npm run build` runs.

Step 1 wraps the database work — `ecto.create`, migrations, and seeds — in one
command; the "Database preparation" section below breaks it down and covers
managed-database caveats.

**Networking.** The app opens exactly one HTTP listener, on `PORT`, speaking
plain HTTP. **TLS termination belongs outside the app** — put a reverse proxy
in front in production and set `APP_TRUST_PROXY_HEADERS=true` there.
**Redis is not used** — background jobs run on Oban over Postgres, so there is
no `REDIS_URL` to configure. Its absence is deliberate, not an oversight.

**FFmpeg only needs manual installation locally.** The deploy image (`Dockerfile`,
in the repository root) and CI already include it, and an image missing FFmpeg
fails the build. It is a runtime dependency for recording processing — build,
boot, and the first screen work without it.

To develop without GCP credentials, set `STT_DEV_MODE=true` to receive mock transcription results.

## Database preparation

On a green-field database, run these from `backend/`, in order:

```bash
mix ecto.create              # create the database
mix ecto.migrate             # run migrations
mix run priv/repo/seeds.exs  # seed data (see "Creating the initial account")
```

Or all three at once with `mix ecto.setup` (already included in `mix setup` above).

**Every step is safe to repeat.** `ecto.create` skips a database that already
exists, each migration runs only once, and the seed script does nothing when an
admin account already exists. Re-running the whole sequence never breaks anything.

**When unsure, run `mix vr.doctor` first.** It checks that the database is
reachable and reports whether your database role can create the required
PostgreSQL extensions — `citext` (case-insensitive text) and `pg_trgm`
(text search) — before a migration fails halfway through.

**If your role cannot create extensions** (common on managed databases), a
database administrator must create them before you run migrations:

```sql
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
```

Both `mix vr.doctor` and the migrations themselves say exactly this when the
privilege is missing, instead of failing with a bare `insufficient_privilege`.

## Deploying a preview (release image)

**A clean checkout reaches a working preview in four actions: build the image,
migrate, seed, start.** The section above is the Mix path, for running from
source. This one is the release path — there is no `mix` inside the image, so
every command here is `bin/vr`, the release launcher.

### 1. What a preview actually needs

The platform provides `DATABASE_URL` and `PORT`. Everything else is on you, and
it is a short list:

| Variable | Secret? | Why a preview needs it |
|---|---|---|
| `DATABASE_URL` | platform-provided | **Required** — migrate, seed, and the app all connect through it |
| `PORT` | platform-provided | **Optional** — what the app listens on. Empty means `4000` |
| `SECRET_KEY_BASE` | **secret** — `mix phx.gen.secret`, or any 64+ random bytes | **Required to start** — signs and encrypts cookies. Migrations never read it |
| `CLOAK_KEY` | **secret** — `openssl rand -base64 32` | **Required to start and to seed** — encrypts settings stored in the DB |
| `PHX_HOST` | no | **Required** — the hostname the preview answers on. Stamped onto the links the app itself generates |
| `PHX_SCHEME` | no | **Required over plain HTTP** — set it to `http`; leave it empty behind a TLS terminator. See step 4 |
| `APP_BASE_URL` | no | **Required for share links and account mail** — the whole public address, e.g. `http://preview.example.test`. Not derived from the two above |
| `BOOTSTRAP_ADMIN_EMAIL` | no | **Optional** — the address of the first admin account. Without it, nobody can open `/_admin` |

**Generate the two secrets, keep them in the platform's secret store, and never
commit them.** There are no defaults in the code for either, and no default
admin address — a value shared by every deployment is a target, not a
convenience.

**`APP_BASE_URL` is the second URL source, and nothing derives it from the
first.** `PHX_HOST` / `PHX_SCHEME` configure the endpoint, which stamps the URLs
the app generates for itself — the Khala OAuth callback, MCP discovery metadata.
`APP_BASE_URL` is a settings-registry value, and it is the one that
`VR.Sharing.link_url/1` and every account email read. Leave it empty and the
preview still answers 200, wrongly: share links come back as bare paths
(`/share/<token>`) that nobody can open from a chat message, and account mail is
never sent at all — the notifier stops rather than mail a link to nowhere. Give
it the same scheme, host and public port you gave the endpoint.

Nothing reads `APP_BASE_URL` at boot, so neither entry point stops for it: a
wrong value shows up as a wrong link, never as a failed start or a
`migration_failed`. It is also the one variable here you can correct later
without a redeploy — a value saved in `/_admin` wins over the environment
([docs/07-config-admin.md](docs/07-config-admin.md#serving-over-plain-http--the-public-url)).

Nothing else is required. Storage, transcription, LLM, mail and push are all
off until configured, and the app boots, serves, and signs you in without them
([docs/00-setup-checklist.md](docs/00-setup-checklist.md) covers turning them
on). **Redis is not one of them** — there is no `REDIS_URL`, here or anywhere
else in this repo.

### 2. Build

```bash
docker build -t khala-voice .    # from the repository root
```

**The build context is the repository root, and the `Dockerfile` is there too.**
One multi-stage build produces the whole image: the React app from `apps/web`,
then the Elixir release from `backend`, with the built assets copied into it. A
build run from inside `backend/` cannot see `apps/web` and will not produce a
usable image.

### 3. Prepare the database, then start

```bash
# inside the container — /app is the release root

# migrate, then seed: one command, in this order
/app/bin/vr eval 'VR.Release.migrate(); VR.Release.seed()'

# start the HTTP server on PORT
/app/bin/vr start
```

`deploy.toml` already carries the first line, so a platform that reads it runs
the preparation step for you; run it by hand only when deploying without one.
The second line is the image's own `CMD`, so starting the container normally is
enough — `PHX_SERVER=true` is baked into the image, which is what tells a
release to start the HTTP server at all.

**Both halves are safe to repeat.** Each migration runs once and is then
recorded; the seed creates each row only when it is absent. Re-running the line
on every deploy is the intended usage, not a first-boot special case.

`VR.Release.migrate()` stops **before migrating anything** if `DATABASE_URL` is
missing, the database is unreachable, or a required PostgreSQL extension cannot
be created — naming the value, or the administrator action and the exact SQL.
If your database role cannot create extensions, pre-provision them exactly as in
"Database preparation" above; the migration then finds them already there and
skips creating them. The full decision is in
[docs/16-postgres-extension-privileges.md](docs/16-postgres-extension-privileges.md).

`VR.Release.seed()` creates the credit conversion policy, the free plan, and the
initial admin from `BOOTSTRAP_ADMIN_EMAIL` / `BOOTSTRAP_ADMIN_PASSWORD`.
**Omit the password and one is generated and printed once, in the deploy log** —
it cannot be recovered afterwards, because only the hash is stored. A password
you set yourself is deliberately *not* printed. With no email configured the
admin is skipped, not failed: everything else is seeded, and the log says what
to set and how to run the step again.

`bin/vr start` needs `SECRET_KEY_BASE` and `CLOAK_KEY` — the preparation step
above does not. That split is why a missing app secret no longer stops a
migration; [docs/07-config-admin.md](docs/07-config-admin.md#entry-points--what-each-one-actually-requires)
has the full entry-point table.

### 4. Serving over plain HTTP

A preview with no TLS in front of it says so in both URL sources:

```bash
PHX_HOST=preview.example.test
PHX_SCHEME=http
APP_BASE_URL=http://preview.example.test
```

**Without `PHX_SCHEME=http` the app serves fine but hands out `https://` links
to an origin that does not answer** — the Khala OAuth callback and MCP discovery
metadata break together, and neither looks like a configuration problem. Add
`PHX_URL_PORT` only when the *public* port is also non-standard
(`http://host:4000` with nothing in front of it). Behind a TLS terminator, leave
both empty. Share, invite and password-reset links are **not** fixed by this
variable — they carry whatever `APP_BASE_URL` says, so it needs the same scheme
(step 1).

A value that is neither `http` nor `https` halts `bin/vr start`, naming the
variable. It does **not** halt the database preparation step, which generates
no links: that step warns and carries on, so a typo here never reaches you as
`migration_failed`
([docs/17](docs/17-runtime-entry-points.md)).

No forced HTTPS redirect is configured and no HSTS header is sent, so nothing
pins the preview hostname to https in a browser. The PWA degrades rather than
erroring: the manifest and service worker use root-relative URLs only, and
registration is skipped on an insecure origin. Microphone capture is the one
real casualty — `getUserMedia` requires a secure context, so recording needs
https or `localhost` regardless of these settings.
[docs/07-config-admin.md](docs/07-config-admin.md#serving-over-plain-http--the-public-url)
covers each variable.

### 5. Smoke check

```bash
curl -L http://preview.example.test/   # → 302 → /go/meetings → 302 → /login → 200
```

The login screen answering 200 means build, migration, seed, and start all
succeeded. Sign in with the bootstrap admin, then read
[docs/00-setup-checklist.md](docs/00-setup-checklist.md) to configure the rest.

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

A password you supply this way is **not printed back.** You already have it, and a
terminal scrollback or a deploy log is one more place it can leak from.

If you omit the password, **a random one is generated and printed to the screen once.**
Write it down at that moment — only the hash is stored in the DB, so it cannot be viewed again.

```bash
BOOTSTRAP_ADMIN_EMAIL=admin@example.com mix run priv/repo/seeds.exs
# → Created the initial admin account
#
#       Email     admin@example.com
#       Password  xxxxxxxxxxxxxxxxxxxxxxxx
#
#     This password is only shown right now. Save it somewhere.
```

`mix vr.bootstrap_admin` creates the same account without the other seed rows, and
reports the same outcomes — including when a deploy's seed step created the admin at
the same moment.

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
