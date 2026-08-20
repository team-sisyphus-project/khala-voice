# KHALA VOICE — 작업 지침

## 이 리포가 무엇인가

회의 녹음 · 화자분리 전사 · AI 요약 서비스. 데스크톱/모바일 웹 + PWA.
`autosquad/sisyphus`의 Meeting Recorder를 독립시키고,
계정·친구·공유 체계와 `devkanban`의 플랜·크레딧을 결합한 것.
모바일 디자인 시스템은 `devkanban`, 브랜드(이름·아이콘·인트로)는 `khala` 에서 왔다.

설계는 [`docs/`](docs/README.md)에 있다. **코드를 쓰기 전에 관련 문서를 먼저 읽는다.**

| 작업 | 먼저 읽을 문서 |
|---|---|
| 스키마 · 마이그레이션 | `docs/03-domain-model.md` |
| 녹음 · 업로드 · 전사 · 요약 | `docs/04-pipeline.md` |
| 로그인 · 권한 · 공유 | `docs/05-auth-sharing.md` |
| 크레딧 · 플랜 | `docs/06-billing.md` |
| 설정값 · API 키 · 어드민 | `docs/07-config-admin.md` |
| 라우팅 · 프론트 구조 · 내비게이션 · 디자인 시스템 | `docs/08-frontend.md` |
| sisyphus/devkanban에서 가져올 때 | `docs/10-porting-map.md` |

## 절대 규칙

### 1. 시크릿을 코드에 넣지 않는다

이 리포는 오픈소스로 공개된다.

- API 키 · 토큰 · 비밀번호 · 자격증명을 코드 · 설정 · 시드 · 테스트 · 문서에 쓰지 않는다
- 설정값은 **반드시** `VR.Config.fetch/2`로만 읽는다.
  각 모듈에서 `System.get_env`를 직접 부르지 않는다
- `VR.Config`는 `DB → 환경변수 → nil` 순으로 해석한다. **리터럴 기본값을 두지 않는다**
- 새 설정값을 추가하면 `.env.example`과 `docs/07-config-admin.md`를 함께 갱신한다
- 사용자가 채팅에 붙여넣은 키를 파일에 쓰지 않는다. 어드민 화면이나 `.env`로 안내한다

### 2. 권한 명칭은 Reviewer / Contributor / Viewer

한국어 UI에서도 이 영문 명칭을 그대로 쓴다.
"검토자 / 참여자 / 조회자"로 번역하지 않는다.
내부 코드값은 `lv0` / `lv1` / `lv2` / `lv3`(접근 불가).

### 3. 접근 불가는 404

권한이 없는 리소스는 `403`이 아니라 `404`로 응답한다. 존재 여부를 노출하지 않는다.

### 3-1. 스타일은 `packages/ui-styles` 한 곳에만 둔다

웹앱(React)과 LiveView가 **같은 파일**을 읽는다. 복사본을 만들지 않는다.

- `packages/ui-styles/devkanban/` 은 **원본과 같아야 한다.** 손대지 않는다
- 이 앱의 조정은 전부 `overrides.css` 에 쓰고, **왜 덮었는지**를 `docs/14-provenance.md` 에 남긴다
- 마크업의 클래스 이름이 곧 계약이다 (`mobile-button` · `mobile-section` · `bottom-nav` …).
  이름을 바꾸면 두 화면이 같이 깨진다

### 4. 비즈니스 로직은 `packages/core`에 둔다

`packages/core`에 React 의존성을 넣지 않는다.
녹음 엔진 · 업로드 큐 · 도메인 변환 · 권한 판정은 UI에서 분리한다.
sisyphus는 이 로직을 데스크톱/모바일에 두 벌 복사해 두었다가 동작이 갈렸다.

### 5. 서버가 최종 판정한다

프론트의 버튼 비활성화는 편의일 뿐이다. 모든 변경 API는 서버에서 역할을 다시 계산한다.

### 6. 가져온 것은 출처를 남긴다

sisyphus / devkanban 에서 이식한 것은 **두 곳 모두**에 적는다.

1. 모듈 `@moduledoc` (또는 파일 상단 주석) 에 원본 경로
   ```elixir
   @moduledoc """
   ...
   **출처: sisyphus** `lib/sisyphus/meetings/google_stt.ex` — 거의 그대로.
   """
   ```
2. [`docs/14-provenance.md`](docs/14-provenance.md) 의 표

**"그대로"인지 "무엇을 바꿨는지"를 반드시 적는다.** 원본이 고쳐졌을 때
여기도 고쳐야 하는지 판단하는 기준이 된다.
원본의 결정 근거도 함께 옮긴다 — 사라지면 같은 논의를 반복한다.

## 이식할 때

sisyphus에서 코드를 가져올 때는 `docs/10-porting-map.md`의 대조표를 따르고,
같은 문서의 **알려진 결함(B1~B7)** 을 함께 고친다. 그대로 옮기면 버그도 옮겨간다.

특히 손대지 말아야 할 것:
- `GoogleSTT` — GCS 왕복 · 폴링 · 결과 파싱 · 정리까지 실전에서 다듬어진 코드
- IndexedDB 업로드 큐 — 저장 → 업로드 → 성공 시 제거 순서가 유실 방지의 핵심
- 화자 2계층 구조 — `segments[].speaker`와 `speaker_map`을 합치지 않는다
- 요약 프롬프트의 출처 추출 규칙 — 요약 클릭 → 오디오 점프가 여기에 달려 있다

## 개발 환경

- FFmpeg(`ffmpeg`, `ffprobe`) 필요
- GCP 자격증명 없이 개발하려면 `STT_DEV_MODE=true`
- `CLOAK_KEY`가 없으면 앱이 부팅되지 않는다 (의도된 동작)
