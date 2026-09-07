# 00. Setup Checklist — Where the Keys Go

> **Never paste keys into chat or issues.** They go in through the two paths below only.

## There are exactly two input paths

| Path | When | Storage |
|---|---|---|
| **Admin UI** `/_admin/…` | After deployment (recommended) | DB, Cloak AES-256-GCM encrypted |
| **`.env` file** | Local development | A file. Commits blocked via `.gitignore` |

If both are set, **the DB (admin) wins.** So after deployment you only need to manage keys in the admin UI.

---

## Checklist

### 1. Storage (S3) — required for recording uploads

| Item | Admin | `.env` |
|---|---|---|
| Bucket name | `/_admin/settings/storage` | `STORAGE_BUCKET` |
| Region | 〃 | `STORAGE_REGION` |
| **Access Key ID** | 〃 | `STORAGE_ACCESS_KEY_ID` |
| **Secret Access Key** | 〃 | `STORAGE_SECRET_ACCESS_KEY` |
| CDN base URL | 〃 | `STORAGE_CDN_BASE_URL` |

Required permissions: `s3:PutObject` and `s3:GetObject` on the bucket.

> 🔒 **Keep the bucket private (no public-read).**
> Object keys follow `data/meetings/{meeting_id}/sessions/{session_id}/{started_at_unix}.{ext}`,
> which is **fully deterministic**. Anyone who can view a meeting receives all these values
> in API responses, so if the bucket is public, both Viewer masking and share-link role
> restrictions are completely bypassed.
> The app issues a signed URL for every playback (`GET /api/sessions/:id/audio`).
>
> We also recommend **enabling bucket versioning**. If a re-issued presign accidentally
> overwrites the same key, versioning lets you recover the original. (The app never
> re-issues a presign for a session whose upload has completed.)

> ⚠️ **Rotation required**: the keys currently in the local `.env` are the same keys
> committed in plaintext in three `n8n-workflows/*.json` files in the `autosquad/sisyphus`
> repo. Issue new keys, swap them in, and deactivate the old ones.
> We recommend a dedicated bucket (or a separate prefix) for this app.

### 2. Transcription (Google Cloud STT v2) — required for transcription

| Item | Admin | `.env` |
|---|---|---|
| **Service account JSON** | `/_admin/settings/stt` | `STT_CREDENTIALS_JSON` |
| GCP project ID | 〃 | `STT_PROJECT_ID` |
| Region (default `us`) | 〃 | `STT_LOCATION` |
| Recognizer name | 〃 | `STT_RECOGNIZER` |
| **GCS staging bucket** | 〃 | `STT_GCS_BUCKET` |
| Dev mode | 〃 | `STT_DEV_MODE` |

- Paste the **entire contents** of the service account JSON file
- Required permissions: Speech-to-Text usage; read/write/delete on the GCS staging bucket
- Why a GCS bucket is needed: `batchRecognize` only accepts `gs://` paths
- **To develop without keys**, set `STT_DEV_MODE=true` — mock transcription results are returned

### 3. AI summary (LLM) — required for summaries

Add a provider at `/_admin/llm`.

| Item | Value |
|---|---|
| Provider | `gemini` (default) / `anthropic` / `openai` |
| Model ID | e.g. `gemini-2.5-flash` |
| **API key** | Issued from the provider's console |
| Billing tier | `high` / `mid` / `low` — used for credit conversion |
| Priority | Lower goes first. On failure, falls back to the next provider |

`.env` fallback: `LLM_PROVIDER`, `LLM_API_KEY`, `LLM_MODEL`

### 4. Social login — optional

Enter keys per provider at `/_admin/social` and **turn them on** for the buttons to appear on the login screen.

| Item | `.env` fallback |
|---|---|
| Client ID | `{PROVIDER}_OAUTH_CLIENT_ID` |
| **Client Secret** | `{PROVIDER}_OAUTH_CLIENT_SECRET` |
| Redirect URI | `{PROVIDER}_OAUTH_REDIRECT_URI` |

- The Redirect URI must be registered **identically** in the provider's console
- **ON/OFF lives in the DB only.** Environment variables cannot enable a provider
- The enable toggle is disabled while keys are missing
- Email + password login is always on and cannot be turned off

### 5. Mail — needed for invitations and password resets

| Item | Admin | `.env` |
|---|---|---|
| Provider | `/_admin/settings/mail` | `MAIL_PROVIDER` |
| Sending domain | 〃 | `MAIL_DOMAIN` |
| **API key** | 〃 | `MAIL_API_KEY` |

For local development use `MAIL_PROVIDER=local` — nothing is actually sent; mail piles up at `/dev/mailbox`.

### 6. Web push — optional

| Item | Admin | `.env` |
|---|---|---|
| VAPID public key | `/_admin/settings/push` | `VAPID_PUBLIC_KEY` |
| **VAPID private key** | 〃 | `VAPID_PRIVATE_KEY` |
| VAPID subject | 〃 | `VAPID_SUBJECT` |

### 7. Admin access

| Item | `.env` |
|---|---|
| Admin username | `ADMIN_USERNAME` |
| **Admin password** | `ADMIN_PASSWORD` |

- **Must be set in production.** If missing, the admin UI is blocked with a 503
  (a missing setting must never mean the admin UI is wide open)
- In development, missing credentials simply pass through
- Once M1 replaces this with account-based access (`Account.is_admin`), this item goes away

### 8. The app itself — required to boot

| Item | `.env` | Notes |
|---|---|---|
| `DATABASE_URL` | ✅ | |
| `SECRET_KEY_BASE` | ✅ | `mix phx.gen.secret` |
| **`CLOAK_KEY`** | ✅ | `openssl rand -base64 32` — **boot fails without it** |
| `PHX_HOST` / `APP_BASE_URL` | ✅ | |
| `PORT` | — | **Optional.** Empty means `4000`. If the deployment platform injects one, that value wins |
| `PHX_SCHEME` / `PHX_URL_PORT` | — | **Optional.** Empty means `https` on 443 — the right pair behind a TLS terminator. Set `PHX_SCHEME=http` for a preview served over plain HTTP, so generated links point where the app actually answers ([07](07-config-admin.md#serving-over-plain-http--the-public-url)) |

> If you lose `CLOAK_KEY`, **every key stored in the DB becomes undecryptable.**
> Keep a separate copy in your deployment environment's secret manager. Rotating the key
> requires decrypting the existing values and re-encrypting them.

---

## Checking progress

The `/_admin` dashboard tells you what is missing, per feature.

```
Recording upload   working
Transcription      not configured — needs: service account JSON, GCP project ID, GCS staging bucket
AI summary         not configured — needs: LLM API key
Mail delivery      working
Web push           working
```

## System requirements — what is automatic, what is manual

**Bottom line: deployment and CI are fully automatic. Only each developer's local machine needs a one-time install.**

| Tool | Local dev | Production deploy | CI |
|---|---|---|---|
| **FFmpeg** | Manual `brew install ffmpeg` | **Automatic** — included in `backend/Dockerfile` | **Automatic** — `apt-get install` in the workflow |
| **gitleaks** | Manual `brew install gitleaks` | Not needed | **Automatic** — `gitleaks-action` |
| PostgreSQL | Manual (or Docker) | Managed DB | **Automatic** — service container |

### Why deployment is automatic

The runtime stage of `backend/Dockerfile` installs FFmpeg and **verifies it at build time**.

```dockerfile
RUN apt-get install -y --no-install-recommends ... ffmpeg
RUN ffmpeg -version > /dev/null && ffprobe -version > /dev/null
```

The second line is the key — an image missing FFmpeg **fails the build itself**.
This prevents an FFmpeg-less image from reaching production and transcription dying silently.

CI also installs FFmpeg in `.github/workflows/ci.yml` and runs the gitleaks action.
Even if you forget gitleaks locally, it gets caught at the PR stage.

### Local install

```bash
brew install ffmpeg gitleaks
./scripts/install-hooks.sh      # pre-commit hook (once)
```

### Health check

```bash
mix vr.doctor
```

Shows system tools, DB, required settings, and per-feature readiness in one shot.
In production, the admin dashboard (`/_admin`) shows the same information.

```
━━━ System tools ━━━
  ✅ ffmpeg             audio splitting / MP3 conversion
  ✅ gitleaks           blocks secrets at commit time

━━━ Feature readiness ━━━
  ✅ Recording upload        working
  ⚠️  Transcription          not configured — needs: service account JSON, GCP project ID, GCS staging bucket
```

Without FFmpeg, splitting and MP3 conversion fail for recordings over 20 minutes.
Warnings also appear on the admin dashboard and in the app's boot log.
