# 07. Configuration, Secrets, System Admin

> **This repo will be published as open source.** No credential of any kind may appear
> in code, config files, seeds, test fixtures, or documentation.

## Config resolution order

All external credentials and operational settings are read through **exactly one path**.

```elixir
VR.Config.fetch(:storage, :access_key_id)

#  1) DB           system_configs / auth_providers / llm_providers   (Cloak encrypted)
#  2) env var      System.get_env("STORAGE_ACCESS_KEY_ID")
#  3) nil          → feature disabled + shown as "not configured" in admin
```

**Rules**

| # | Rule |
|---|---|
| R1 | No literal defaults in code. If a value is missing, the feature stays off |
| R2 | Only `VR.Config` reads values. Individual modules never call `System.get_env` directly |
| R3 | Secrets never appear in logs, error messages, or API responses (`redact`) |
| R4 | The admin UI never echoes stored secrets back. Masked + "configured / not configured" only |
| R5 | Missing `CLOAK_KEY` means **boot failure**. No default key is generated |

> **Scope of R1 and R2 — boot parameters are the exception.**
> These two rules govern the **credentials** handled by `VR.Config`.
> Boot parameters are needed before the Repo is up, so they cannot come from the DB;
> they are read directly via `System.get_env` in `config/runtime.exs` and have literal
> defaults. The complete list: `PHX_SERVER`, `PORT`, `HTTPS_PORT`, `PHX_SCHEME`,
> `PHX_URL_PORT`, `DEV_BIND_ALL`, `ECTO_IPV6`, `POOL_SIZE`, `DNS_CLUSTER_QUERY`.
> (`DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, and `CLOAK_KEY` are also read in
> `runtime.exs` because they are needed at boot, but they are **not** part of the
> defaults exception — the first two raise when missing in prod, and a missing
> `CLOAK_KEY` blocks boot per R5.)
> Boot parameters are not secrets, and there is no feature to disable when they are
> absent. To add a new item to this exception, first answer "is it needed before the
> Repo?" If it is a credential, the answer is always `VR.Config.Registry`.

## Preventing secret incidents

| Mechanism | Contents |
|---|---|
| `.env.example` | Lists key names only; every value is an empty string |
| `.gitignore` | `.env*` (except `.env.example`), `*.pem`, `*credentials*.json` |
| pre-commit hook | `gitleaks protect --staged` — blocks the commit itself |
| CI | `gitleaks detect` scans full history. Build fails on findings |
| Seeds | Dummy values only. No seed ever contains a real key |
| PR template | A "no secrets added" checkbox |

> **Note (a real incident)**: three `n8n-workflows/*.json` files in the sisyphus repo had
> AWS access keys/secrets committed in plaintext. This category (config JSON, workflow
> exports, notebooks, screenshots) is the most common leak path. The gitleaks rules
> include `*.json` export files.

## Encryption

```elixir
VR.Vault              # Cloak.Vault, AES-256-GCM, key from CLOAK_KEY (base64, 32 bytes)
VR.Encrypted.Binary   # Ecto type. Encrypts on write, decrypts on load

field :client_secret, VR.Encrypted.Binary, source: :client_secret_encrypted
```
Key generation: `openssl rand -base64 32`

---

## Configuration schemas

### SystemConfig — generic key-value
```elixir
id, key, value, encrypted :boolean, description, updated_by_id
```

| Group | Key | Encrypted |
|---|---|---|
| **Storage** | `storage.provider` (`s3`) | |
| | `storage.bucket`, `storage.region` | |
| | `storage.access_key_id` | ✅ |
| | `storage.secret_access_key` | ✅ |
| | `storage.cdn_base_url` | |
| | `storage.download_url_ttl_seconds` | |
| **Google STT** | `stt.credentials_json` (service account JSON) | ✅ |
| | `stt.project_id`, `stt.location`, `stt.recognizer` | |
| | `stt.gcs_bucket` (batchRecognize staging bucket) | |
| | `stt.dev_mode` (mock responses) | |
| **Mail** | `mail.provider`, `mail.domain` | |
| | `mail.api_key` | ✅ |
| **Push** | `push.vapid_public_key` | |
| | `push.vapid_private_key` | ✅ |
| | `push.vapid_subject` | |
| **Policy** | `policy.invite_code_required` | |
| | `policy.hard_stop_on_zero_credits` (default false) | |
| **App** | `app.base_url` | |
| | `app.timezone` (default `Asia/Seoul`) | |
| | `app.trust_proxy_headers` (default false) | |
| **AI summary** | `llm.dev_mode` | |
| | `llm.auto_summarize` | |
| **Admin access** | `admin.username` | |
| | `admin.password` | ✅ |

> **Admin access (temporary for M0)**: with no account system yet, HTTP Basic auth is
> used. In dev, missing credentials pass through; **in prod, missing credentials block
> with a 503** — a missing setting must never mean the admin UI is wide open.
> M1 replaces this with `Account.is_admin`-based access and this entry is removed.

### AuthProvider — social login
```elixir
id, provider, display_name,
client_id, client_secret(encrypted), redirect_uri, scopes,
enabled :boolean, sort_order, updated_by_id
```
Activation checks and safety mechanisms are in [05-auth-sharing.md](05-auth-sharing.md#social-login-onoff).

### LlmProvider — LLM for summaries
```elixir
id, provider,          # gemini | anthropic | openai
   display_name,
   api_key(encrypted),
   base_url,           # for proxy/compatible endpoints (optional)
   model,              # actual model ID
   tier,               # ModelPricing join key (high|mid|low)
   temperature,        # default 0.2
   max_output_tokens,  # default 16384
   enabled :boolean,
   priority :integer   # lower goes first. On failure, falls back to the next provider
```

**Selection logic**
```
among enabled = true with an api_key, ascending priority → use the first
call failure (rate limit / 5xx) → fall back to the next priority
all failed → summary_failed, recorded in last_summary_error
```

### CommerceSettings — public-facing naming
```elixir
credit_term :map, plan_term :map, locale_overrides :map
```

---

## Environment variables

`.env.example` lists names only (enforced by `backend/test/vr/env_example_test.exs`,
which also checks that every variable `config/runtime.exs` reads appears in the
template). For credentials, environment variables are purely a fallback when the DB
is unset.

**Before running migrations or the server locally**, fill in the **Required (app)**
block — none of those values are platform-injected. Everything else can stay empty:
features without configuration are simply off, and boot parameters have defaults.

**Platform-injected values** (do not set locally):

| Variable | Injected by |
|---|---|
| `PORT` | Deploy platform. A platform value wins; empty means 4000. This is what the app **listens on** — see "Serving over plain HTTP" below for what it *claims to be* |
| `PHX_SERVER` | Dockerfile (`ENV PHX_SERVER="true"`). Tells a release to start the HTTP server; `mix phx.server` does not need it |
| `RELEASE_COMMAND` | The release launcher (`bin/vr`), as the command it was given: `start`, `daemon`, `eval`, `rpc`, `remote`. Unset under Mix. See "Entry points" below |

### Entry points — what each one actually requires

**These values are one group in the configuration spec — boot infrastructure —
but three conditions, and no single command needs all of them.** A release
evaluates `config/runtime.exs` for **every** command it is given, the migration
step included, so what a value is required *for* is decided by the entry point,
not by the environment:

| Requirement | `bin/vr start` · `mix phx.server` | `bin/vr eval 'VR.Release.migrate()'` | `bin/vr eval 'VR.Release.seed()'` | `mix ecto.migrate` · `mix setup` |
|---|---|---|---|---|
| `DATABASE_URL` | required | **required** | **required** | required (dev falls back to the local defaults in `config/dev.exs`) |
| `SECRET_KEY_BASE` | required | not read | not read | not read in dev/test |
| `CLOAK_KEY` | required (`VR.Vault` refuses to boot) | not read | **required** | required — `mix` tasks boot the app |

The columns group into three conditions. The first two are branches in
`config/runtime.exs`. The third is not a branch at all — it is what an operator
has to have in hand before anyone can sign in, and it is the one the table above
cannot show, because no single command halts on it.

**1. App boot — `DATABASE_URL`, `SECRET_KEY_BASE`, `CLOAK_KEY`.** The entry
points are `bin/vr start`, `mix phx.server`, and every Mix task
(`mix ecto.migrate`, `mix setup`, `mix vr.bootstrap_admin`) — a Mix task boots
the app, which is why it belongs here and not with the migration below. All
three are required because something is actually started: the Endpoint signs and
encrypts cookies with `SECRET_KEY_BASE`, and `VR.Vault` refuses to boot without
`CLOAK_KEY`.

**2. Migration only — `DATABASE_URL`, and nothing else.** The entry point is
`bin/vr eval 'VR.Release.migrate()'`, the migration step in `deploy.toml`.
`eval` runs one expression on a **non-booted** system: no Endpoint, no Vault, no
supervision tree. It still evaluates the whole of `config/runtime.exs` on the
way in, app-boot values included — that evaluation is incidental, not a
requirement, and mistaking one for the other is the entire defect: requiring the
app's secrets there is what turned a missing `SECRET_KEY_BASE` into a
`migration_failed` with nothing about migrations in it. `runtime.exs` tells the
two apart through `RELEASE_COMMAND`; Mix never sets it, so `mix ecto.migrate`
and `mix setup` behave exactly as before.

The seed step is the one exception to "an `eval` needs nothing": it writes
application data, and reads configuration the way the app does — DB first, and
`system_configs` values are encrypted. So `VR.Release.seed/1` starts `VR.Vault`
and says up front that it needs `CLOAK_KEY`, rather than letting `VR.Config`
quietly fall back to the environment and ignore a value an operator set in the
admin UI. It still starts no Endpoint, so `SECRET_KEY_BASE` stays out of it.
Any deployment that runs the app already has `CLOAK_KEY` — the app does not boot
without one.

**3. Preview preparation — `PHX_HOST`, `PHX_SCHEME`, `APP_BASE_URL`,
`BOOTSTRAP_ADMIN_EMAIL`, on top of the two conditions above.** Its entry point
is not one command but the four that take a green-field database to a preview
somebody can sign in to: `docker build`, `bin/vr eval 'VR.Release.migrate()'`,
`bin/vr eval 'VR.Release.seed()'`, `bin/vr start`. Conditions 1 and 2 get the
app *running*; these four values are what make it *usable*, and every one of
them is **non-secret** — the only secrets a preview needs are `SECRET_KEY_BASE`
and `CLOAK_KEY`, generated per deployment and never committed, and
`DATABASE_URL` / `PORT` come from the platform. Leave all four empty and the app
still answers 200, wrongly: `PHX_HOST` and `PHX_SCHEME` decide whether the links
the app generates point at an origin that answers, `APP_BASE_URL` decides
whether share links and account mail carry a whole address, and without
`BOOTSTRAP_ADMIN_EMAIL` the seed skips the admin row, so `/_admin` has nobody who
can open it. Each is defined below; the sequence that uses them is
[Deploying a preview](../README.md#1-what-a-preview-actually-needs).

**Production is not this list plus more secrets — it is this list with two
values decided differently.** `PHX_SCHEME` is *empty* in the usual production
shape (the default, `https`, is what a TLS terminator in front of the app wants)
and set to `http` only where nothing terminates TLS, which is the preview case;
`BOOTSTRAP_ADMIN_EMAIL` is a first-run value an existing deployment has already
consumed. What production adds beyond this is not boot configuration at all:
storage, transcription, LLM, mail and push are settings-registry values, off
until configured, and the app boots, serves and signs you in without them
([00-setup-checklist.md](00-setup-checklist.md)).

The first two conditions also decide what a **malformed** value stops. `PORT`,
`HTTPS_PORT`, `PHX_SCHEME` and `PHX_URL_PORT` describe how the world reaches a
running app, so a wrong one halts the app and only warns at the database
preparation entry point, which reads none of them:

| Value | `bin/vr start` · `mix phx.server` · Mix tasks | `bin/vr eval …` |
|---|---|---|
| `DATABASE_URL` missing | halts | **halts** — preparation genuinely reads it |
| `PORT` · `HTTPS_PORT` · `PHX_SCHEME` · `PHX_URL_PORT` malformed | halts | warns on stderr, continues on the default |
| `PORT` · `PHX_URL_PORT` empty | default | default — empty means "not decided" |

The warning quotes, word for word, the message the app halts with, and adds
which command will halt on it. Why it warns rather than halts, and what was
decided before, is in
[`17-runtime-entry-points.md`](17-runtime-entry-points.md).

`mix vr.bootstrap_admin` is not a fourth column: it is a Mix task, so it boots
the app and needs exactly what the last column needs. It appears here only
because it writes one of the rows the seed step writes — see "Preparing the
database" below.

`mix vr.doctor` prints the first two conditions as three rows — one per command,
each naming the value it adds — and follows it with the seed rows a prepared
database should hold. A row's mark answers "can this command run right now", not
"is this variable set": a checkout whose connection comes from `config/dev.exs`
is not reported as a broken migration. The seed rows carry the command that
creates each missing one, which is where `mix vr.bootstrap_admin` is named.

`VR.Release.migrate/0` then states its own requirement — a missing
`DATABASE_URL`, an unreachable database, or an extension the role cannot create
each stops it **before** anything is migrated, with a message naming the value
or the administrator action and the command to re-run. Extension privileges are
covered in [`16-postgres-extension-privileges.md`](16-postgres-extension-privileges.md).

### Preparing the database — migrate, then seed

`deploy.toml` runs both in one command, in this order:

```toml
migrate = "/app/bin/vr eval 'VR.Release.migrate(); VR.Release.seed()'"
```

`;` sequences them inside a single `eval`, so the seed runs only when the
migration returned without raising. Both are idempotent, which is what makes the
line safe on every deploy rather than only the first.

`VR.Release.seed/1` creates three things, each only when absent:

| Row | Without it |
|---|---|
| credit conversion policy | usage cannot be priced — transcription and summarization run unmetered |
| the free plan | signups have nothing to be subscribed to |
| the initial admin, from `BOOTSTRAP_ADMIN_EMAIL` / `BOOTSTRAP_ADMIN_PASSWORD` | `/_admin` cannot be opened by anyone |

The admin is **skipped, not failed**, when no email is configured: the rest is
seeded and the message says what to set and how to run it again. There is no
default address — one shared across every deployment would itself be the target.
A generated password is printed once because nothing else can show it; a
password the operator configured is *not* printed — the same `Password` line
comes out naming `BOOTSTRAP_ADMIN_PASSWORD`, since this output is a deploy log
and the operator already has the value.

**Three commands create that admin row, and one module decides what they say.**
`VR.Release.BootstrapAdmin` holds the four outcomes — created, already there
(a run that got there first reports the same one), no address configured, the
address was refused — so the three cannot drift into three answers. What each
command *does* with the third one is the column on the right:

| Command | Creates | Fatal when no email is configured |
|---|---|---|
| `bin/vr eval 'VR.Release.seed()'` | all three rows | no — the step reports the skip and the other two are seeded |
| `mix run priv/repo/seeds.exs` | all three rows | no — same, from a checkout |
| `mix vr.bootstrap_admin` | the admin row only | **yes** — creating it is the whole command, so nothing happened |

Fatality is the one thing the entry point still decides, and it decides it for
the reason above: a skipped step inside a longer run is not a command that did
nothing. Everything else — wording, the diagnostic block, whether the password is
printed — is one string, chosen once.

`priv/repo/seeds.exs` is the same code — it calls `VR.Release.seed/1` and passes
its own command name for the messages, so a checkout is never told to run a
release command. A release has no Mix and cannot run that file, and two copies
would have drifted.

### Serving over plain HTTP — the public URL

`PORT` is what the app listens on. `PHX_HOST` / `PHX_SCHEME` / `PHX_URL_PORT`
are what it **claims to be**: the scheme, host and port Phoenix stamps onto
every absolute URL it generates.

| Variable | Empty means | Sets |
|---|---|---|
| `PHX_HOST` | `localhost` | the host in generated URLs, and the only thing `check_origin` compares |
| `PHX_SCHEME` | `https` | `http` or `https`. Any other value halts the app |
| `PHX_URL_PORT` | `443` for https, `80` for http | the port in generated URLs. A malformed value halts the app |

The two are deliberately separate. Behind a TLS terminator the app listens on
plain HTTP port 4000 while the world reaches it at `https://host` — the normal
production shape, and the one you get by setting neither variable.

A preview with no TLS in front of it is the other shape, and it used to be
unreachable in practice. `url:` was pinned to `https`/443, so the app served
fine over HTTP while handing out `https://` links to an origin that does not
answer. Two things broke at once and neither looked like a configuration
problem:

| What | Why it breaks |
|---|---|
| the Khala OAuth callback (`/khala/callback`) | the `redirect_uri` must match the one registered with Khala exactly |
| MCP discovery metadata (`resource`, `resource_documentation`, the `WWW-Authenticate` header) | clients follow the URL they are given |

So for a preview reachable at `http://preview.example.test`:

```bash
PHX_HOST=preview.example.test
PHX_SCHEME=http
```

Add `PHX_URL_PORT` only when the *public* port is also non-standard — a preview
served directly on `http://preview.example.test:4000`, with nothing in front of
it. Behind a proxy it stays empty: `PORT=4000` and `PHX_URL_PORT` unset is the
right pairing for `http://host` on 80.

**`APP_BASE_URL` is the second URL source, and the endpoint does not feed it.**
The three variables above only reach URLs Phoenix builds from the endpoint. The
links a person receives are built elsewhere, from the registry value
`app.base_url`:

| Built from the endpoint (`PHX_*`) | Built from `app.base_url` (`APP_BASE_URL`) |
|---|---|
| the Khala OAuth callback (`VRWeb.Endpoint.url/0`) | share links — `VR.Sharing.link_url/1` |
| MCP discovery metadata and the `WWW-Authenticate` header | email confirmation, password reset, friend invitation — `VR.Accounts.Notifier` |

With the endpoint variables set and this one empty the app still serves, and the
damage is quiet: a share link comes back as the bare path `/share/<token>`, and
every account email is abandoned before delivery with
`{:missing_config, "app.base_url"}` — the notifier will not mail a link it
cannot make absolute. Nothing reconciles the
two, so they are kept in step by hand: `APP_BASE_URL` carries the same scheme,
host and public port that `PHX_SCHEME` / `PHX_HOST` / `PHX_URL_PORT` describe.

They stay separate because they resolve differently. The endpoint's three values
are read once at boot by `config/runtime.exs`, and a bad one halts the app
([`17-runtime-entry-points.md`](17-runtime-entry-points.md)). `app.base_url` goes
through the normal registry order — DB, then environment — so it is read at the
moment a link is built, is editable in `/_admin` without a redeploy, and halts
nothing, including the migration step.

Two things this does **not** turn on:

- **No forced HTTPS redirect.** `force_ssl` is not configured and no HSTS header
  is sent. An HSTS header served once over a preview hostname would pin that
  host to https in the browser for its whole `max-age`, outliving the preview.
- **No change to `check_origin`.** It is left at the Phoenix default, which
  compares the request's `Origin` **host** against `PHX_HOST` — not the scheme,
  not the port. A plain-HTTP LiveView socket is accepted on the same terms as an
  https one, provided `PHX_HOST` names the host the preview is actually served
  from.

The browser still treats a plain-HTTP origin as insecure, and that is not
something configuration can change. The PWA degrades rather than erroring:
`manifest.webmanifest` and `sw.js` use only root-relative URLs, so they resolve
against whatever origin serves the page, and service-worker registration is
guarded by feature detection and a silent `catch` — on an insecure origin the
browser does not expose `navigator.serviceWorker`, the registration is skipped,
and the app runs without it. Microphone capture is the real casualty:
`getUserMedia` requires a secure context, so recording needs https (or
`localhost`) regardless of these settings.

**`REDIS_URL` is deliberately not used.** This app has no Redis dependency
(background jobs run on Oban over Postgres), so the variable appears neither here
nor in `.env.example` — the absence is intentional, not an oversight.

```bash
# ── Required — three conditions, see above ─
DATABASE_URL=                  # format: ecto://USER:PASS@localhost/DATABASE
SECRET_KEY_BASE=               # generate: mix phx.gen.secret
CLOAK_KEY=                     # openssl rand -base64 32 (boot fails without it)
PHX_HOST=                      # public host (preview/prod; if empty, localhost)
PHX_SCHEME=                    # http | https in generated links. If empty, https
PHX_URL_PORT=                  # public port in generated links. If empty, 443 / 80
PORT=                          # optional — if empty, 4000. Malformed value halts boot
APP_BASE_URL=                  # base URL in share links and emails (not PHX_HOST)

# ── Boot / release (usually leave empty locally) ─
PHX_SERVER=                    # platform-injected via Dockerfile ENV (releases only)
RELEASE_COMMAND=               # release-injected: which bin/vr command is running
ECTO_IPV6=                     # true | 1 = DB over IPv6 (prod releases only)
POOL_SIZE=                     # DB pool size (prod releases only). If empty, 10
DNS_CLUSTER_QUERY=             # node clustering DNS name. If empty, clustering off
DEV_BIND_ALL=                  # dev only: true = additionally serve HTTPS
HTTPS_PORT=                    # if empty, 4001. Malformed value halts boot
# REDIS_URL is intentionally absent: this app does not use Redis.

# ── Storage (S3) ───────────────────────────
STORAGE_BUCKET=
STORAGE_REGION=
STORAGE_ACCESS_KEY_ID=
STORAGE_SECRET_ACCESS_KEY=
STORAGE_CDN_BASE_URL=
STORAGE_DOWNLOAD_URL_TTL_SECONDS=   # if empty, derived from recording length

# ── Google Cloud STT ───────────────────────
STT_CREDENTIALS_JSON=
STT_PROJECT_ID=
STT_LOCATION=
STT_RECOGNIZER=
STT_GCS_BUCKET=
STT_DEV_MODE=                  # true = mock responses, no real calls

# ── LLM (summary) ──────────────────────────
LLM_PROVIDER=                  # gemini | anthropic | openai
LLM_API_KEY=
LLM_MODEL=
LLM_DEV_MODE=                  # true = mock summary without calling the LLM
LLM_AUTO_SUMMARIZE=            # true = summarize when transcription finishes

# ── Social login (optional) ────────────────
GOOGLE_OAUTH_CLIENT_ID=
GOOGLE_OAUTH_CLIENT_SECRET=
GOOGLE_OAUTH_REDIRECT_URI=
GITHUB_OAUTH_CLIENT_ID=
GITHUB_OAUTH_CLIENT_SECRET=
GITHUB_OAUTH_REDIRECT_URI=

# ── Mail · push ────────────────────────────
MAIL_PROVIDER=
MAIL_DOMAIN=
MAIL_API_KEY=
VAPID_PUBLIC_KEY=
VAPID_PRIVATE_KEY=
VAPID_SUBJECT=

# ── App behavior ───────────────────────────
APP_TRUST_PROXY_HEADERS=       # true only behind a reverse proxy
APP_TIMEZONE=                  # if empty, Asia/Seoul

# ── Initial admin (first run only) ─────────
BOOTSTRAP_ADMIN_EMAIL=         # no default — without it no admin account is created
BOOTSTRAP_ADMIN_PASSWORD=      # if empty, generated and printed once

# ── Khala integration ──────────────────────
KHALA_ENABLED=
KHALA_MCP_URL=                 # e.g. https://mcp.khala.to/mcp — no secret (PKCE)
```

> **Social login `enabled` cannot be turned on via environment variables.** Keys may come
> from the environment, but enabling happens in the admin UI. This prevents login methods
> from changing accidentally across deployment environments.

---

## System admin (`/_admin`)

Phoenix LiveView. Accessible only with `Account.is_admin = true`.

| Group | Screen | Contents |
|---|---|---|
| **Settings** | Storage | S3 bucket, region, keys, CDN. [Test connection] button |
| | Transcription (STT) | GCP credentials, project, region, recognizer, GCS bucket, dev mode |
| | LLM | Provider list CRUD. Keys, models, priority, ON/OFF. [Test call] |
| | Social login | Per-provider keys + ON/OFF. Warns with affected account count before disabling |
| | Mail · push | Delivery settings |
| | Policy | Whether signup invite codes are required, credit hard-stop switch |
| **Pricing** | ServicePricing | External API unit prices (STT etc.) → credit conversion rates |
| | ModelPricing | Per-LLM-model unit prices → credit conversion rates |
| **Commerce** | Plans | Plan CRUD, revision publish history, separate metadata/commercial editing |
| | Subscriptions | Per-account subscription view, plan changes |
| | Credits | Balance view, manual grant/revoke (reason required), ledger timeline |
| | Terminology | Public-facing credit naming + preview |
| | Audit log | BillingAuditLog view |
| **Operations** | Accounts | Search, status, sessions, deletion scheduling |
| | Meetings | Search, status, session states, retry failed items |
| | Jobs | Oban queue status, failed jobs, retries |
| | Logs | Transcription/summary failure logs |

### Admin UI rules

1. Secret fields **never echo the stored value back.** Show `••••••••` + "configured (updated 2026-08-19)"
2. On save, an empty value **keeps the existing one** (prevents accidental deletion). Deleting is a separate [Clear] button
3. External integration settings get a **[Test connection]** button. Validity must be checkable before saving
4. Every admin settings change is written to the audit log with `updated_by_id`
5. Unconfigured items are collected into a **warning banner** at the top of the dashboard
   (e.g. "AI summary is disabled because no LLM provider is configured")
