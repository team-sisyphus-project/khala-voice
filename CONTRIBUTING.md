# 기여 안내

이 리포지토리는 회의 녹음을 다룬다. **사람의 대화가 저장되는 서비스**라
보안과 개인정보에 관한 규칙이 다른 어떤 규칙보다 앞선다.

## 시작하기

```bash
brew install ffmpeg gitleaks      # macOS. 리눅스는 apt-get install ffmpeg gitleaks
./scripts/install-hooks.sh        # 커밋 시 시크릿 차단 훅 — 반드시 설치한다

cp .env.example .env
openssl rand -base64 32           # CLOAK_KEY 에 넣는다

cd backend && mix setup && mix vr.doctor
```

`mix vr.doctor` 가 어떤 기능이 켜져 있고 무엇이 빠졌는지 알려준다.
GCP 자격증명이 없으면 `STT_DEV_MODE=true`, LLM 키가 없으면 `LLM_DEV_MODE=true` 로
목 응답을 받아 전체 화면을 확인할 수 있다.

## 절대 규칙

### 1. 시크릿을 코드에 넣지 않는다

- API 키 · 토큰 · 비밀번호를 코드 · 설정 · 시드 · 테스트 · 문서에 쓰지 않는다
- 설정값은 **반드시** `VR.Config.fetch/2` 로만 읽는다. `System.get_env` 를 직접 부르지 않는다
- `VR.Config` 는 `DB → 환경변수 → nil` 순으로 해석한다. **리터럴 기본값을 두지 않는다** —
  값이 없으면 그 기능이 꺼져야지, 아무 값으로나 동작하면 안 된다
- 새 설정값을 추가하면 `.env.example` 과 `docs/07-config-admin.md` 를 함께 갱신한다

`gitleaks` 가 pre-commit 과 CI 에서 막지만, 훅은 마지막 방어선이지 첫 방어선이 아니다.

### 2. 권한 명칭은 Reviewer / Contributor / Viewer

한국어 UI 에서도 이 영문 명칭을 그대로 쓴다. "검토자 / 참여자 / 조회자" 로 번역하지 않는다.
내부 코드값은 `lv0` / `lv1` / `lv2` / `lv3`(접근 불가).

### 3. 접근 불가는 404 다

권한이 없는 리소스는 `403` 이 아니라 `404` 로 응답한다.
403 은 "그 리소스는 있는데 네가 못 볼 뿐" 을 알려준다.

`FallbackController` 에 403 절을 추가하지 마라.

### 4. 비즈니스 로직은 `packages/core` 에 둔다

`packages/core` 에 React 나 DOM API 를 넣지 않는다. 다운로드 헬퍼도 안 된다.
녹음 엔진 · 업로드 큐 · 도메인 변환 · 권한 판정은 UI 에서 분리한다.

### 5. 서버가 최종 판정한다

프런트의 버튼 비활성화는 편의일 뿐이다. 모든 변경 API 는 서버에서 역할을 다시 계산한다.

### 6. 가져온 것은 출처를 남긴다

이 앱은 두 리포지토리에서 코드를 이식했다 (`sisyphus`, `devkanban`).
이식한 것은 **두 곳 모두**에 적는다.

1. 모듈 `@moduledoc` 에 원본 경로
2. [`docs/14-provenance.md`](docs/14-provenance.md) 의 표

**"그대로" 인지 "무엇을 바꿨는지" 를 반드시 적는다.** 원본이 고쳐졌을 때
여기도 고쳐야 하는지 판단하는 기준이 된다. 원본의 결정 근거도 함께 옮긴다 —
사라지면 같은 논의를 반복한다.

## 손대기 전에 읽을 것

| 작업 | 문서 |
|---|---|
| 스키마 · 마이그레이션 | [`docs/03-domain-model.md`](docs/03-domain-model.md) |
| 녹음 · 업로드 · 전사 · 요약 | [`docs/04-pipeline.md`](docs/04-pipeline.md) |
| 로그인 · 권한 · 공유 | [`docs/05-auth-sharing.md`](docs/05-auth-sharing.md) |
| 크레딧 · 플랜 | [`docs/06-billing.md`](docs/06-billing.md) |
| 설정값 · API 키 · 어드민 | [`docs/07-config-admin.md`](docs/07-config-admin.md) |
| 라우팅 · 프론트 구조 | [`docs/08-frontend.md`](docs/08-frontend.md) |

## 손대면 안 되는 것

실전에서 다듬어진 코드다. 고칠 이유가 분명하지 않으면 두는 편이 낫다.

- **`VR.Transcription.GoogleSTT`** — GCS 왕복 · 폴링 · 결과 파싱 · 정리까지
- **IndexedDB 업로드 큐** — 저장 → 업로드 → 성공 시 제거 순서가 유실 방지의 핵심이다
- **화자 2계층 구조** — `segments[].speaker` 와 `speaker_map` 을 합치지 않는다.
  `speaker_map` 은 **세션별**이라 세션마다 `speaker_1` 이 다른 사람일 수 있다
- **요약 프롬프트의 출처 추출 규칙** — 요약 클릭 → 오디오 점프가 여기에 달려 있다.
  `[session_id|speaker|HH:MM:SS]` 직렬화 형식을 바꾸면 통째로 깨진다

## 검사

보내기 전에 전부 통과해야 한다.

```bash
cd backend && mix precommit          # compile --warnings-as-errors → format → test
cd packages/core && npm test && npm run typecheck
cd apps/web && npm run build         # tsc --noEmit 포함
gitleaks detect --no-git -c .gitleaks.toml
```

CI 도 같은 것을 돌린다. **경고는 실패다** — 미사용 alias 하나로 빌드가 깨진다.

## 테스트

- 테스트 이름은 한국어로, **무엇이 보장되는지** 를 쓴다 ("동작한다" 말고)
- 고친 버그에는 회귀 테스트를 붙인다. 고치기 전에 그 테스트가 **실제로 실패하는지 확인**한다
- 보안 관련 수정에는 "이렇게 하면 뚫린다" 를 재현하는 테스트를 남긴다
- 동시성 테스트에서 `Ecto.Adapters.SQL.Sandbox.allow/3` 의 소유자는 **테스트 프로세스**다.
  태스크 안에서 `self()` 를 넘기면 그 연결이 샌드박스 밖으로 나가 테스트 DB 에 실제로 커밋된다

## 주석

- 한국어로 쓴다
- **무엇** 이 아니라 **왜** 를 쓴다. 코드가 하는 일은 코드를 읽으면 안다
- 특히 "이렇게 안 하면 무엇이 깨지는지" 를 남긴다. 나중에 누가 "정리" 하려 들 때 막아준다

## 보안 문제를 발견했다면

이슈로 열지 말고 [SECURITY.md](SECURITY.md) 를 따라 비공개로 알려주세요.
