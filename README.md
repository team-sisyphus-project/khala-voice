# KHALA VOICE

브라우저에서 회의를 녹음하고, 화자를 분리해 전사하고, AI로 요약하는 서비스.
데스크톱 웹 · 모바일 웹 · PWA를 지원한다.

```
녹음 → 자동 업로드 → 화자분리 전사 → AI 요약 → 친구/링크 공유 → 아카이브 검색
```

## 기능

| | |
|---|---|
| **녹음** | 브라우저에서 바로. 일시정지·재개, 화면 꺼짐 방지, 중단 감지. 오프라인이면 IndexedDB 에 쌓였다가 자동 업로드 |
| **전사** | Google Cloud STT v2(Chirp) 화자분리. 20분을 넘으면 자동 분할 |
| **편집** | 화자 이름·친구 연결, 발언별 화자 교정, 본문 수정, 세그먼트 분할, 원본 복원 |
| **요약** | Gemini · Claude · GPT 중 선택. **요약 항목을 누르면 그 말이 나온 지점이 재생된다** |
| **공유** | 친구 공개 범위 4단계 + 1회성 링크(PIN · 만료 · 역할 지정) |
| **분류** | 토픽·라벨로 아카이브를 검색. 필터가 URL 에 들어가 그대로 공유된다 |
| **크레딧** | 플랜 지급 + 사용량 계량. 무엇에 얼마가 나갔는지 근거까지 보여준다 |
| **PWA** | 홈 화면 설치, 전사·요약 완료 푸시 알림 |

화면은 **회의**(바로 녹음) · **아카이브**(회의 목록·검색) · **친구** · **설정** 네 탭이다.

## 문서

설계 문서는 [`docs/`](docs/README.md)에 있다. 시작은 [docs/01-overview.md](docs/01-overview.md).

## 스택

Phoenix (Elixir) · PostgreSQL · Oban · React + TypeScript · AWS S3 ·
Google Cloud Speech-to-Text v2 · LLM (Gemini / Anthropic / OpenAI)

## 보안 원칙

**이 리포지토리는 오픈소스로 공개된다. 어떤 자격증명도 코드에 들어가서는 안 된다.**

- 모든 설정은 `DB → 환경변수 → 없음` 순으로만 해석한다 ([docs/07](docs/07-config-admin.md))
- 코드에 리터럴 기본값을 두지 않는다. 값이 없으면 해당 기능이 꺼진다
- DB에 저장되는 비밀값은 Cloak(AES-256-GCM)으로 암호화한다
- `gitleaks`가 pre-commit과 CI에서 커밋을 차단한다

기여 전 `.env.example`을 복사해 `.env`를 만들고, **`.env`는 절대 커밋하지 않는다.**

## 개발

```bash
brew install ffmpeg gitleaks   # macOS. 리눅스는 apt-get install ffmpeg
./scripts/install-hooks.sh     # 커밋 시 시크릿 차단 훅

cp .env.example .env           # 값을 채운다. .env는 커밋되지 않는다
openssl rand -base64 32        # CLOAK_KEY 생성

cd backend
mix setup
mix vr.doctor                  # 환경·설정 점검
mix phx.server
```

**FFmpeg은 로컬에만 수동 설치가 필요하다.** 배포 이미지(`backend/Dockerfile`)와
CI에는 이미 포함되어 있고, FFmpeg이 빠진 이미지는 빌드가 실패한다.

GCP 자격증명 없이 개발하려면 `STT_DEV_MODE=true`로 목 전사 결과를 받을 수 있다.

## 시스템 어드민

### 초기 계정 만들기

**기본 아이디도 기본 비밀번호도 코드에 없다.** 모든 배포본이 같은 값을 쓰면
그 자체가 공격 대상이 되기 때문이다. 처음 한 번은 직접 정해서 만든다.

```bash
cd backend

# 아이디(이메일)와 비밀번호를 직접 정한다
BOOTSTRAP_ADMIN_EMAIL=admin@example.com \
BOOTSTRAP_ADMIN_PASSWORD='직접-정한-강한-비밀번호' \
  mix run priv/repo/seeds.exs
```

비밀번호를 주지 않으면 **무작위로 만들어 화면에 한 번 출력한다.** 그때 받아 적어야 한다
(DB 에는 해시만 남아 다시 볼 수 없다).

```bash
BOOTSTRAP_ADMIN_EMAIL=admin@example.com mix run priv/repo/seeds.exs
# → 초기 어드민 계정을 만들었습니다
#   이메일: admin@example.com
#   비밀번호: xxxxxxxxxxxx      ← 이 화면에서만 보인다
```

이미 어드민이 하나라도 있으면 이 명령은 아무것도 하지 않는다.

기존 계정을 어드민으로 올리거나 내리려면:

```bash
mix vr.make_admin you@example.com
mix vr.make_admin you@example.com --revoke
```

**어드민은 화면에서 스스로 승격할 수 없다.** 어드민 화면이 뚫려도 권한 상승으로
이어지지 않게 하기 위해서다.

### 들어가는 방법

`/_admin` **주소를 직접 입력해서만** 들어간다. 앱 어디에도 링크가 없다 —
일반 사용자에게 그런 화면의 존재를 노출하지 않기 위해서다.
권한 없는 요청에는 403 이 아니라 **404** 로 답한다.

### 2단계 인증은 의무다

어드민 계정은 **2단계 인증(TOTP)을 켜야 `/_admin` 에 들어갈 수 있다.**
안 켠 상태로 접근하면 설정 화면으로 돌려보낸다.
어드민 하나가 뚫리면 전체 시스템의 설정과 API 키가 함께 넘어가기 때문이다.

일반 사용자에게는 요구하지 않는다.

> 개발·스테이징(`MIX_ENV != :prod`)에서는 **아무 6자리 숫자나 통과**한다.
> 인증기 앱 없이 화면을 확인할 수 있게 한 것이고, 이 우회는 **컴파일 시점에 박혀**
> 운영 빌드에서는 환경변수로도 켤 수 없다.

### 부트스트랩 계정을 지운다

실사용자 계정을 만들어 어드민으로 올린 뒤, 초기 계정은 삭제한다.
입구를 하나 줄이는 것이 목적이다.

## 기여

[CONTRIBUTING.md](CONTRIBUTING.md) 를 읽어주세요. 보안 문제는
[SECURITY.md](SECURITY.md) 를 따라 **비공개로** 알려주세요.

## 운영 전 확인

- **S3 버킷을 비공개로 둘 것** — 저장 경로가 결정적이라 공개 버킷이면 접근 제어가 무의미해집니다
- `CLOAK_KEY` 를 DB 자격증명과 다른 곳에 보관
- 프록시 뒤일 때만 `APP_TRUST_PROXY_HEADERS=true`
- 어드민 MFA 를 켜고 부트스트랩 계정 삭제

자세한 내용은 [SECURITY.md](SECURITY.md) 와
[docs/00-setup-checklist.md](docs/00-setup-checklist.md).

## 라이선스

아직 정하지 않았습니다. 정해지기 전까지는 모든 권리가 유보됩니다.
