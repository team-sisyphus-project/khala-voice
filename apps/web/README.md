# @vr/web

회의 · 녹음 · 전사 · 요약 화면. React + TypeScript + Vite.

## 개발

```bash
npm install
npm run dev      # vite build --watch → backend/priv/static/app
```

Vite 개발 서버를 따로 띄우지 않는다. Phoenix 가 전부 서빙하고
Vite 는 파일만 갱신한다. 서버가 하나라 쿠키·CSRF·실기기 접속 주소가 어긋나지 않는다.

Phoenix 를 함께 띄운다.

```bash
cd ../../backend && mix phx.server
```

`http://localhost:4000/app/meetings`

## 규칙

1. **비즈니스 로직은 `@core` 에 둔다.** 이 패키지에는 화면과 얇은 어댑터만 있다.
   `src/hooks/useRecorder.ts` 처럼 코어를 React 에 연결하는 정도가 상한이다.
2. **스타일은 `.vr-*` 클래스를 쓴다.** `backend/assets/css/app.css` 에 있고
   어드민(LiveView)과 같은 파일을 공유한다. 색 리터럴을 쓰지 않는다.
3. **권한 판정은 서버가 한다.** 응답의 `role` 은 UI 를 그릴 때만 쓴다.
   버튼을 숨기는 것은 편의일 뿐, 서버가 다시 검증한다.

## 라우트

| 경로 | 화면 |
|---|---|
| `/app/meetings` | 회의 목록 |
| `/app/meetings/:id` | 회의 상세 — 녹음 · 세션 · 요약 탭 |
| `/app/archive` | 아카이브 검색 |

로그인·친구·설정은 Phoenix LiveView 가 담당한다 (`/login`, `/friends`, `/settings`).
