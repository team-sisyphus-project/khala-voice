# 00. 설정 체크리스트 — 키를 어디에 넣는가

> **채팅이나 이슈에 키를 붙여넣지 마세요.** 아래 두 경로로만 입력합니다.

## 입력 경로는 두 곳

| 경로 | 언제 | 저장 위치 |
|---|---|---|
| **어드민 화면** `/_admin/…` | 배포 후 (권장) | DB, Cloak AES-256-GCM 암호화 |
| **`.env` 파일** | 로컬 개발 | 파일. `.gitignore`로 커밋 차단 |

둘 다 있으면 **DB(어드민)가 이깁니다.** 그래서 배포 후에는 어드민에서만 관리하면 됩니다.

---

## 체크리스트

### 1. 스토리지 (S3) — 녹음 업로드에 필수

| 항목 | 어드민 | `.env` |
|---|---|---|
| 버킷 이름 | `/_admin/settings/storage` | `STORAGE_BUCKET` |
| 리전 | 〃 | `STORAGE_REGION` |
| **Access Key ID** | 〃 | `STORAGE_ACCESS_KEY_ID` |
| **Secret Access Key** | 〃 | `STORAGE_SECRET_ACCESS_KEY` |
| CDN 기본 URL | 〃 | `STORAGE_CDN_BASE_URL` |

필요 권한: 해당 버킷에 대한 `s3:PutObject`, `s3:GetObject`.

> 🔒 **버킷을 반드시 비공개로 두세요 (public-read 금지).**
> 저장 경로가 `data/meetings/{meeting_id}/sessions/{session_id}/{started_at_unix}.{ext}` 로
> **완전히 결정적**입니다. 회의를 볼 수 있는 사람이면 이 값들을 API 응답으로 다 받으므로,
> 버킷이 공개면 Viewer 마스킹도 공유 링크의 역할 제한도 전부 우회됩니다.
> 앱은 재생할 때마다 서명된 URL 을 발급합니다 (`GET /api/sessions/:id/audio`).
>
> 버킷 **버저닝을 켜두는 것**도 권합니다. presign 재발급으로 같은 키를 덮어쓰는 사고에서
> 원본을 되살릴 수 있습니다. (앱은 업로드가 끝난 세션에 presign 을 다시 내주지 않습니다.)

> ⚠️ **로테이션 필요**: 현재 로컬 `.env`에 들어간 키는 `autosquad/sisyphus` 리포의
> `n8n-workflows/*.json` 3개 파일에 평문으로 커밋되어 있는 키입니다.
> 새 키를 발급해 교체하고, 기존 키는 비활성화하세요.
> 이 앱 전용 버킷(또는 별도 prefix)을 쓰는 것을 권합니다.

### 2. 전사 (Google Cloud STT v2) — 전사에 필수

| 항목 | 어드민 | `.env` |
|---|---|---|
| **서비스 계정 JSON** | `/_admin/settings/stt` | `STT_CREDENTIALS_JSON` |
| GCP 프로젝트 ID | 〃 | `STT_PROJECT_ID` |
| 리전 (기본 `us`) | 〃 | `STT_LOCATION` |
| Recognizer 이름 | 〃 | `STT_RECOGNIZER` |
| **GCS 임시 버킷** | 〃 | `STT_GCS_BUCKET` |
| 개발 모드 | 〃 | `STT_DEV_MODE` |

- 서비스 계정 JSON은 **파일 내용 전체**를 붙여넣습니다
- 필요 권한: Speech-to-Text 사용, GCS 임시 버킷 읽기/쓰기/삭제
- GCS 버킷이 필요한 이유: `batchRecognize`가 `gs://` 경로만 받습니다
- **키 없이 개발하려면** `STT_DEV_MODE=true` — 목 전사 결과가 반환됩니다

### 3. AI 요약 (LLM) — 요약에 필수

`/_admin/llm` 에서 제공자를 추가합니다.

| 항목 | 값 |
|---|---|
| 제공자 | `gemini` (기본) / `anthropic` / `openai` |
| 모델 ID | 예: `gemini-2.5-flash` |
| **API 키** | 제공자 콘솔에서 발급 |
| 과금 tier | `high` / `mid` / `low` — 크레딧 환산에 사용 |
| 우선순위 | 낮을수록 먼저. 실패 시 다음 제공자로 폴백 |

`.env` 폴백: `LLM_PROVIDER`, `LLM_API_KEY`, `LLM_MODEL`

### 4. 소셜 로그인 — 선택

`/_admin/social` 에서 제공자별로 키를 넣고 **켜야** 로그인 화면에 나타납니다.

| 항목 | `.env` 폴백 |
|---|---|
| Client ID | `{PROVIDER}_OAUTH_CLIENT_ID` |
| **Client Secret** | `{PROVIDER}_OAUTH_CLIENT_SECRET` |
| Redirect URI | `{PROVIDER}_OAUTH_REDIRECT_URI` |

- Redirect URI는 제공자 콘솔에도 **똑같이** 등록해야 합니다
- **ON/OFF 는 DB에서만 합니다.** 환경변수로는 켜지지 않습니다
- 키가 없으면 켜기 버튼이 비활성입니다
- 이메일+비밀번호 로그인은 항상 켜져 있고 끌 수 없습니다

### 5. 메일 — 초대·비밀번호 재설정에 필요

| 항목 | 어드민 | `.env` |
|---|---|---|
| 제공자 | `/_admin/settings/mail` | `MAIL_PROVIDER` |
| 발송 도메인 | 〃 | `MAIL_DOMAIN` |
| **API 키** | 〃 | `MAIL_API_KEY` |

로컬 개발은 `MAIL_PROVIDER=local` — 메일이 발송되지 않고 `/dev/mailbox`에 쌓입니다.

### 6. 웹 푸시 — 선택

| 항목 | 어드민 | `.env` |
|---|---|---|
| VAPID 공개키 | `/_admin/settings/push` | `VAPID_PUBLIC_KEY` |
| **VAPID 비밀키** | 〃 | `VAPID_PRIVATE_KEY` |
| VAPID Subject | 〃 | `VAPID_SUBJECT` |

### 7. 어드민 접근

| 항목 | `.env` |
|---|---|
| 어드민 아이디 | `ADMIN_USERNAME` |
| **어드민 비밀번호** | `ADMIN_PASSWORD` |

- **운영에서는 반드시 설정해야 합니다.** 없으면 어드민이 503으로 막힙니다
  (설정 누락이 곧 어드민 전체 공개가 되는 상황을 만들지 않습니다)
- 개발에서는 없으면 그냥 통과합니다
- M1에서 계정 기반(`Account.is_admin`)으로 교체되면 이 항목은 사라집니다

### 8. 앱 자체 — 부팅에 필수

| 항목 | `.env` | 비고 |
|---|---|---|
| `DATABASE_URL` | ✅ | |
| `SECRET_KEY_BASE` | ✅ | `mix phx.gen.secret` |
| **`CLOAK_KEY`** | ✅ | `openssl rand -base64 32` — **없으면 부팅 실패** |
| `PHX_HOST` / `PORT` / `APP_BASE_URL` | ✅ | |

> `CLOAK_KEY`를 잃어버리면 **DB에 저장된 모든 키를 복호화할 수 없습니다.**
> 배포 환경의 시크릿 매니저에 별도 보관하세요. 키를 바꾸려면 기존 값을
> 복호화해서 다시 암호화하는 절차가 필요합니다.

---

## 진행 상황 확인

`/_admin` 대시보드가 기능별로 무엇이 빠졌는지 알려줍니다.

```
녹음 업로드   동작 중
전사          미설정 — 필요: 서비스 계정 JSON, GCP 프로젝트 ID, GCS 임시 버킷
AI 요약       미설정 — 필요: LLM API 키
메일 발송     동작 중
웹 푸시       동작 중
```

## 시스템 요구사항 — 무엇이 자동이고 무엇이 수동인가

**결론: 배포와 CI는 전부 자동입니다. 개발자 각자의 로컬 머신만 한 번 설치하면 됩니다.**

| 도구 | 로컬 개발 | 운영 배포 | CI |
|---|---|---|---|
| **FFmpeg** | 수동 `brew install ffmpeg` | **자동** — `backend/Dockerfile`에 포함 | **자동** — 워크플로에서 `apt-get install` |
| **gitleaks** | 수동 `brew install gitleaks` | 불필요 | **자동** — `gitleaks-action` |
| PostgreSQL | 수동 (또는 Docker) | 관리형 DB | **자동** — 서비스 컨테이너 |

### 배포는 왜 자동인가

`backend/Dockerfile`의 런타임 스테이지가 FFmpeg을 설치하고, **빌드 시점에 검증**까지 합니다.

```dockerfile
RUN apt-get install -y --no-install-recommends ... ffmpeg
RUN ffmpeg -version > /dev/null && ffprobe -version > /dev/null
```

두 번째 줄이 핵심입니다 — FFmpeg이 빠진 이미지는 **빌드 자체가 실패**합니다.
FFmpeg 없는 이미지가 운영에 올라가서 전사가 조용히 죽는 상황을 막습니다.

CI도 `.github/workflows/ci.yml`에서 FFmpeg을 설치하고 gitleaks 액션을 돌립니다.
로컬에서 gitleaks를 깜빡해도 PR 단계에서 잡힙니다.

### 로컬 설치

```bash
brew install ffmpeg gitleaks
./scripts/install-hooks.sh      # pre-commit 훅 (한 번만)
```

### 점검

```bash
mix vr.doctor
```

시스템 도구 · DB · 필수 설정 · 기능별 준비 상태를 한 번에 보여줍니다.
운영에서는 어드민 대시보드(`/_admin`)가 같은 내용을 보여줍니다.

```
━━━ 시스템 도구 ━━━
  ✅ ffmpeg             오디오 분할 · MP3 변환
  ✅ gitleaks           커밋 시 시크릿 차단

━━━ 기능별 준비 상태 ━━━
  ✅ 녹음 업로드             동작 중
  ⚠️  전사                 미설정 — 필요: 서비스 계정 JSON, GCP 프로젝트 ID, GCS 임시 버킷
```

FFmpeg이 없으면 20분 초과 녹음의 분할과 MP3 변환이 실패합니다.
어드민 대시보드와 앱 부팅 로그에도 경고가 뜹니다.
