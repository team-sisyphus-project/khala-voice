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
> Boot parameters like `PORT`, `HTTPS_PORT`, and `POOL_SIZE` are needed before the Repo
> is up, so they cannot come from the DB; they are read directly via `System.get_env` in
> `config/runtime.exs` and have literal defaults.
> They are not secrets, and there is no feature to disable when they are absent.
> To add a new item to this exception, first answer "is it needed before the Repo?"
> If it is a credential, the answer is always `VR.Config.Registry`.

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

`.env.example` lists names only. Used purely as fallback when the DB is unset.

```bash
# ── Required (app) ─────────────────────────
DATABASE_URL=
SECRET_KEY_BASE=
CLOAK_KEY=                    # openssl rand -base64 32
PHX_HOST=
PORT=                          # optional — empty means 4000
APP_BASE_URL=

# ── Storage (S3) ───────────────────────────
STORAGE_BUCKET=
STORAGE_REGION=
STORAGE_ACCESS_KEY_ID=
STORAGE_SECRET_ACCESS_KEY=
STORAGE_CDN_BASE_URL=

# ── Google Cloud STT ───────────────────────
STT_CREDENTIALS_JSON=
STT_PROJECT_ID=
STT_LOCATION=
STT_RECOGNIZER=
STT_GCS_BUCKET=
STT_DEV_MODE=

# ── LLM (summary) ──────────────────────────
LLM_PROVIDER=
LLM_API_KEY=
LLM_MODEL=

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
