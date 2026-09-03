# Contributing

This repository handles meeting recordings. **It is a service that stores human
conversations**, so the rules about security and privacy come before every other rule.

## Getting started

```bash
brew install ffmpeg gitleaks      # macOS. On Linux: apt-get install ffmpeg gitleaks
./scripts/install-hooks.sh        # secret-blocking commit hook — installation is mandatory

cp .env.example .env
openssl rand -base64 32           # put this in CLOAK_KEY

cd backend && mix setup && mix vr.doctor
```

`mix vr.doctor` tells you which features are enabled and what is missing.
Without GCP credentials, set `STT_DEV_MODE=true`; without an LLM key, set
`LLM_DEV_MODE=true` to get mock responses and walk through every screen.

## Hard rules

### 1. No secrets in code

- Never put API keys, tokens, or passwords in code, config, seeds, tests, or docs
- Read configuration values **only** through `VR.Config.fetch/2`. Never call `System.get_env` directly
- `VR.Config` resolves in the order `DB → environment variable → nil`. **No literal
  defaults** — a missing value must turn the feature off, not make it run with
  an arbitrary value
- When you add a config value, update `.env.example` and `docs/07-config-admin.md` together

`gitleaks` blocks leaks in the pre-commit hook and in CI, but the hook is the
last line of defense, not the first.

### 2. Role names are Reviewer / Contributor / Viewer

Use these English names as-is throughout the UI; do not translate or rename them.
The internal code values are `lv0` / `lv1` / `lv2` / `lv3` (no access).

### 3. No access means 404

Respond to unauthorized resources with `404`, not `403`.
A 403 reveals "the resource exists — you just can't see it."

Do not add a 403 clause to `FallbackController`.

### 4. Business logic lives in `packages/core`

Do not put React or DOM APIs in `packages/core`. Not even download helpers.
The recording engine, upload queue, domain transforms, and permission checks
stay separate from the UI.

### 5. The server has the final say

Disabling buttons on the frontend is a convenience, nothing more. Every mutating
API recomputes the caller's role on the server.

### 6. Imported code keeps its provenance

This app ported code from two repositories (`sisyphus`, `devkanban`).
Record every port in **both** places:

1. The source path in the module's `@moduledoc`
2. The table in [`docs/14-provenance.md`](docs/14-provenance.md)

**Always note whether it was taken "as-is" or "what was changed."** That is the
basis for deciding whether a fix upstream needs to be mirrored here. Carry over
the original's decision rationale too — lose it, and the same debate gets
repeated.

## Read before you touch

| Area | Doc |
|---|---|
| Schema, migrations | [`docs/03-domain-model.md`](docs/03-domain-model.md) |
| Recording, upload, transcription, summary | [`docs/04-pipeline.md`](docs/04-pipeline.md) |
| Login, permissions, sharing | [`docs/05-auth-sharing.md`](docs/05-auth-sharing.md) |
| Credits, plans | [`docs/06-billing.md`](docs/06-billing.md) |
| Config values, API keys, admin | [`docs/07-config-admin.md`](docs/07-config-admin.md) |
| Routing, frontend structure | [`docs/08-frontend.md`](docs/08-frontend.md) |

## Do not touch

This code has been hardened in production. Unless you have a clear reason to
change it, leave it alone.

- **`VR.Transcription.GoogleSTT`** — the whole GCS round trip: polling, result parsing, cleanup
- **The IndexedDB upload queue** — the store → upload → delete-on-success order is what prevents data loss
- **The two-layer speaker structure** — do not merge `segments[].speaker` and `speaker_map`.
  `speaker_map` is **per-session**, so `speaker_1` can be a different person in each session
- **The source-extraction rules in the summary prompt** — click-summary-to-jump-audio depends on them.
  Changing the `[session_id|speaker|HH:MM:SS]` serialization format breaks it wholesale

## Checks

Everything must pass before you submit.

```bash
cd backend && mix precommit          # compile --warnings-as-errors → format → test
cd packages/core && npm test && npm run typecheck
cd apps/web && npm run build         # includes tsc --noEmit
gitleaks detect --no-git -c .gitleaks.toml
```

CI runs the same set. **Warnings are failures** — a single unused alias breaks the build.

## Tests

- Name tests after **what they guarantee** (not "it works")
- Attach a regression test to every bug fix, and **confirm the test actually fails**
  before the fix
- For security fixes, leave a test that reproduces "this is how it gets breached"
- In concurrency tests, the owner in `Ecto.Adapters.SQL.Sandbox.allow/3` is
  **the test process**. Passing `self()` from inside a task takes that connection
  out of the sandbox and really commits to the test DB

## Comments

- Write them in English
- Explain **why**, not **what**. What the code does can be read from the code
- Above all, note "what breaks if you don't do it this way." It stops the next
  person who tries to "clean this up"

## Found a security issue?

Do not open an issue. Follow [SECURITY.md](SECURITY.md) and report it privately.
