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
mix vr.doctor                  # what each command needs, and what the seed left

# 2. React web app — mix setup does NOT build this
cd ../apps/web
npm install
npm run build                  # outputs to backend/priv/static/app/

# 3. Bootstrap admin account (see "Creating the initial account" below)
cd ../../backend
mix vr.bootstrap_admin --email admin@example.com

# 4. Start the server
PORT=4000 mix phx.server       # PORT optional; defaults to 4000
```

**One command runs steps 1, 2 and 4 against a throwaway database and says which
one broke:**

```bash
DATABASE_URL=ecto://USER:PASS@HOST/postgres scripts/verify-preview.sh
```

It builds, creates its own green-field database, migrates, seeds, starts on
`PORT` — 4123 when you have not set one — and then asserts that the first
screen answers **200**, over **plain HTTP** — no `https://` hop, no HSTS — with
**no `REDIS_URL`** in the environment. Its database is dropped on the way out,
passed or failed, so the next run is as green-field as this one, and the
database your `.env` names is never touched. Step 3 runs only when you hand it
`BOOTSTRAP_ADMIN_EMAIL` — without one the `seed` row says the admin was skipped
and the run still passes, which is the same answer step 1 gives. Flags and
rows: ["5. Verify the whole sequence"](#5-verify-the-whole-sequence).

By hand, against the server step 4 started — an anonymous visit to `/`
redirects to the login screen, which answers 200:

```bash
curl -L http://localhost:4000/   # → 302 → /go/meetings → 302 → /login → 200
```

**The React build step (2) is not optional.** `mix setup` builds only the
LiveView assets; `backend/priv/static/app/` is gitignored, so on a clean
checkout everything under `/app/` stays empty until `npm run build` runs.

Step 1 wraps the database work — `ecto.create`, migrations, and seeds — in one
command; the "Database preparation" section below breaks it down and covers
managed-database caveats.

**Step 3 is the same seed step, reached by the command that does only that part.**
The seed inside step 1 creates the credit conversion policy and the free plan, and
skips the admin unless `BOOTSTRAP_ADMIN_EMAIL` is already set — which is why step 1
ends on `❌ admin sign-in`, with step 3's command on the `create:` line under it.
Step 3 does not re-do step 1's work, and running step 1 again does not undo step
3's. "Creating the initial account" below has all three ways in.

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
exists, each migration runs only once, and the seed creates each of its rows only
when that row is absent — the three are checked independently, so an admin that
already exists does not stop the other two from being seeded. Re-running the whole
sequence never breaks anything.

**When unsure, run `mix vr.doctor` first.** It checks that the database is
reachable and reports whether your database role can create the required
PostgreSQL extensions — `citext` (case-insensitive text) and `pg_trgm`
(text search) — before a migration fails halfway through.

It also reports the other two things this sequence can go wrong on. **Required
config** is listed per entry point — `migrate`, `seed`, `app boot`, each needing
everything the one before it needs — so a value the migration never reads is
never shown as stopping it. **Seed data** lists the rows the seed leaves behind,
each with the command that creates it when it is missing:

```
━━━ Required config, by entry point ━━━
  ✅ migrate            DATABASE_URL not set — using config/dev.exs
  ✅ seed               CLOAK_KEY set
  ❌ app boot           SECRET_KEY_BASE missing

━━━ Seed data ━━━
  ✅ credit conversion  1 credit = $0.0015
  ✅ free plan          3000 credits/month
  ❌ admin sign-in      no admin — /_admin cannot be opened by anyone
       create: mix vr.bootstrap_admin --email you@example.com
```

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
you set yourself is deliberately *not* printed: the same line comes out naming
`BOOTSTRAP_ADMIN_PASSWORD` instead of repeating its value into a log. With no
email configured the admin is skipped, not failed: everything else is seeded, and
the log says what to set and how to run the step again. It is the same mechanism
as `mix vr.bootstrap_admin`, reached from the release path — "Creating the initial
account" below covers all three entry points at once.

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

### 5. Verify the whole sequence

**One command does everything above against a throwaway database and fails
naming the step that broke:**

```bash
export DATABASE_URL=ecto://USER:PASS@HOST/postgres   # any reachable server
scripts/verify-preview.sh --release
```

It builds the image, creates its own green-field database, prepares it with
`deploy.toml`'s own eval line, starts the container by its `CMD` alone, and
only then asks whether the preview works. Every row it prints is one thing that
had to be true; a failing row names the step, quotes the command, points at
that step's log, and exits 1.

| It asserts | How |
|---|---|
| The first screen answers **200** | follows `/` through its redirects and requires 200 at the end of the chain |
| Nothing forces **https** | no hop redirects to `https://`, no `Strict-Transport-Security` header, and the absolute links the app builds from its own config say `http://` |
| **Redis is not needed** | `REDIS_URL` is removed from the environment before anything starts, so no run can pass on one it inherited |
| The database is **green-field** | it creates its own, named after the run, and drops it on the way out — passed or failed |
| The checkout needs no `preview.toml` | the repository root offers exactly one way to build, and the image and `deploy.toml` declare the rest |

There are two modes, and they check the same things about whatever ends up
listening:

| Command | Reach for it when |
|---|---|
| `scripts/verify-preview.sh --release` | the image is what you deploy — docker build, then migrate, seed and start through `bin/vr` inside the container |
| `scripts/verify-preview.sh` | you are running from source — the Mix path (→ ["From clean checkout to running app"](#from-clean-checkout-to-running-app)) |

**The two part on one thing: `--release` skips with exit 0 when docker is
missing or not running.** The `preflight` row then carries a `·` and the words
`not checked`, never a `✅`, and the block under it says in a sentence that
nothing was asserted — read the row, not the status code. The Mix path has no
such exit: it needs `mix` and `npm`, and fails naming whichever is absent.

| Flag | Effect |
|---|---|
| `--release` | verify the release image instead of the Mix path |
| `--port N` | start on N instead of `PORT`, or 4123 when `PORT` is unset |
| `--keep-db` | leave the throwaway database behind to inspect it |
| `-h`, `--help` | print the flags and the values the script reads |

**`DATABASE_URL` is the only value you have to supply** — the throwaway
database is created on the server it names, and the database name in it is left
alone. `PORT` and `BOOTSTRAP_ADMIN_EMAIL` / `BOOTSTRAP_ADMIN_PASSWORD` are
passed through when you set them. The rest of step 1's table is the script's
own: it generates `SECRET_KEY_BASE` and `CLOAK_KEY` for a database that stops
existing a minute later, and sets `PHX_HOST` and `PHX_SCHEME=http` itself,
because plain HTTP is the topology it is there to check. `--release` is handed
those six by name and nothing more — an `APP_BASE_URL` left in your shell never
reaches the container, where it would be verifying your configuration instead
of the image's. Step logs land under `TMPDIR`; the `logs` row says where.

CI runs the Mix mode on every pull request and every push to `main`, as the
`Preview E2E` job, so this sequence goes red when it stops working.

What the script cannot reach is the preview the platform actually deployed. For
that, the same first screen, by hand:

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

**One mechanism creates it, and three commands reach it.** They read the same
`BOOTSTRAP_ADMIN_EMAIL` / `BOOTSTRAP_ADMIN_PASSWORD`, and answer the same four
outcomes in the same sentence — created, an admin was already there (including
when another run got there first), no address was configured, the address was
refused. Only the closing clause differs, and it says how far that run got.
Pick the row that describes where you are:

| Command | Reach for it when |
|---|---|
| `mix vr.bootstrap_admin` | you want the account and nothing else. This is the command `mix vr.doctor` prints when there is no admin |
| `mix run priv/repo/seeds.exs` | you are preparing a checkout's database and want all three seed rows — see "Database preparation" above |
| `bin/vr eval 'VR.Release.seed()'` | you are on the release path, where there is no `mix` — see "Deploying a preview" above |

The rest of this section uses the first one; the other two do the same thing to
the admin row, and their own sections cover what else they do. **They part on one
outcome: no address configured.** The two seed commands skip the admin, seed the
other two rows and exit 0; `mix vr.bootstrap_admin` stops with a non-zero exit,
because creating that account is the whole command. The per-command table is in
[docs/07-config-admin.md](docs/07-config-admin.md#preparing-the-database--migrate-then-seed).

**Supply the password and it is never repeated back to you.** You already have it,
and a terminal scrollback or a deploy log is one more place it can leak from — so
the `Password` line names where the value came from instead of printing it:

```bash
cd backend

BOOTSTRAP_ADMIN_EMAIL=admin@example.com \
BOOTSTRAP_ADMIN_PASSWORD='a-strong-password-you-chose' \
  mix vr.bootstrap_admin
```

```
    Email     admin@example.com
    Password  the value set in BOOTSTRAP_ADMIN_PASSWORD
```

**Omit the password and a random one is generated — printed once, here, and
nowhere else.** Write it down at that moment: only the hash is stored, so it
cannot be looked up again.

```bash
mix vr.bootstrap_admin --email admin@example.com
```

```
┌──────────────────────────────────────────────────────────┐
  Created the initial admin account

    Email     admin@example.com
    Password  xxxxxxxxxxxxxxxxxxxxxxxx

  This password is only shown right now. Save it somewhere.
  Delete this account after promoting a real user to admin.
└──────────────────────────────────────────────────────────┘
```

At a terminal the command prints the four next steps under that box, ending in
deleting this account once a real user has been promoted. `--email` and
`--password` are the same two values by another name — the environment variables
are what the other two commands have to use, having no command line of their own.

**If at least one admin already exists, all three do nothing** — including when a
deploy's seed step created the account at the very same moment. The run that loses
that race reports the account as already there, not as a failed command. That is
what makes step 3 of the clean-checkout sequence, and the seed step of every
deploy, safe to repeat.

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
