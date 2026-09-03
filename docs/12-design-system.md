# 12. 디자인 시스템

`devkanban` 의 테마 체계를 이식했다. 원본: `assets/css/themes/*.css` + `assets/css/app.css` :root.

## 테마 4종 — 사용자마다 고른다

**시스템 어드민 설정이 아니다.** 계정별 값이고 설정 화면에서 각자 바꾼다.

| 테마 | 성격 | 크기 | 로드 |
|---|---|---|---|
| **라이트** | 웜 오프화이트 · 빨강 액센트 | 2KB(gzip) | 번들 포함 |
| **다크** | 웜 차콜 · 빨강 액센트 | 2KB(gzip) | 번들 포함 |
| **연필** | 종이 질감 · 스케치 상자 | 66KB(gzip) | 번들 포함 |
| **게임** | 픽셀(인광관) · 도트 폰트 · 스캔라인 | 10KB(gzip) | 번들 포함 |

### 번들 로드

네 테마 모두 `packages/ui-styles` 번들에 포함한다. 예전 연필·게임 지연 로드 파일은
옛 토큰 이름을 덮어 현재 `--mobile-*` 토큰 체계에서는 화면을 바꾸지 못했으므로
제거했다. 테마 선택은 추가 네트워크 요청 없이 `data-theme`만 전환한다.

### 깜빡임 방지

| 화면 | 방식 |
|---|---|
| LiveView | 서버가 `html[data-theme]` 를 직접 찍는다 |
| React SPA | 정적 `index.html` 이라 localStorage 캐시로 먼저 칠하고, `/api/me` 로 정정 |

## 기본 테마

브라우저 캐시와 계정 값이 없으면 라이트를 사용한다. React SPA는 정적 문서의 첫
페인트와 `cachedTheme()`에서, LiveView와 신규 계정은 서버 기본값에서 같은 규칙을
적용한다. 사용자가 저장한 유효한 테마는 그대로 유지한다.

## 액센트 — 빨강

devkanban 은 오렌지지만 이 앱은 **빨강**이다. 녹음 버튼이 빨강이고
(빨간 원 = 녹음 중, 만국 공통) 액센트가 따로 놀면 어색하다.

`accent.css` 가 테마 파일 뒤에서 `--accent` 계열만 덮는다.
서피스·글자·선은 건드리지 않는다 — 각 테마의 정체성이 거기 있다.

**게임 테마는 예외로 둔다.** 빨강·초록·앰버가 각각 "층 · 오브젝트 · 실행"을 뜻하는
선 문법이라 액센트를 바꾸면 그 의미 체계가 깨진다.

## 토큰 계약

`packages/ui-styles/devkanban/tokens.css`가 이름 목록과 테마별 값을 제공한다.
각 `[data-theme="…"]` 블록이 공용 `--mobile-*` 토큰을 덮는다.

### 서피스 사다리

`canvas` 가 가장 뒤, 숫자가 클수록 앞으로 나온다.

| 토큰 | 쓰임 |
|---|---|
| `--surface-canvas` | 페이지 바닥 |
| `--surface-0` | 섹션 |
| `--surface-1` | 카드 |
| `--surface-2` | 카드 위의 요소 |
| `--surface-3` | 모달 · 팝오버 |
| `--surface-inset` | 눌린 자리 (입력란) |

### 그 외

| 그룹 | 토큰 |
|---|---|
| 글자 | `--text-primary` `--text-secondary` `--text-tertiary` `--text-faint` |
| 선 | `--border-subtle` `--border-default` `--border-strong` `--divider` |
| 액센트 | `--accent` `--accent-hover` `--accent-soft` `--accent-strong` `--accent-text` |
| 상태 | `--status-{info,success,warning,error,attention}` (+ `-soft`) |
| 그림자 | `--elev-1~3` `--elev-overlay` |
| 모서리 | `--radius-{xs,sm,md,lg,xl,full}` |

**상태 색은 매체가 바뀌어도 계열을 유지한다.** 미학이 아니라 의미론이다.

## data-surface 역할

연필·게임 같은 매체 테마는 **컴포넌트가 아니라 역할**을 칠한다.
그래야 컴포넌트가 늘어도 스킨이 안 늘어난다.

| 역할 | 무엇 |
|---|---|
| `raised` | 바닥 위에 뜬 것 — 카드 · 패널 · 모달 · 드롭다운 |
| `sunken` | 값을 써 넣는 자리 — input · textarea · select |
| `control` | 누르는 것 — 버튼 · 칩 · 탭 · 토글 |

**태그가 없으면 안 칠해진다.** 새 컨테이너·입력·버튼을 만들면 반드시 붙인다.

## 컴포넌트 클래스

`backend/assets/css/app.css`. LiveView 와 React 가 **같은 파일**을 쓴다.

| 클래스 | 용도 |
|---|---|
| `.vr-card` / `.vr-card__body` | 카드 |
| `.vr-notice--{info,warn,error,ok}` | 알림 배너 |
| `.vr-chip--{ok,warn,error,info,neutral}` | 상태 칩 |
| `.vr-btn` `--primary` `--danger` `--ghost` `--outline` `--sm` | 버튼 |
| `.vr-input` | 입력 |
| `.vr-label` / `.vr-hint` / `.vr-key` | 라벨 · 도움말 · 설정 키 |
| `.vr-app__*` / `.vr-tabbar__*` | React 앱 껍데기 · 하단 탭바 |

## 테마를 타지 않는 것

의도적으로 고정한 값들이다.

| 항목 | 이유 |
|---|---|
| **녹음 버튼 빨강** (`--rec-*`) | 빨간 원 = 녹음 중은 만국 공통 관습이다 |
| **화자 팔레트 10색** | 화자 구분이 목적이라 테마마다 바뀌면 혼란스럽다 |
| **아이콘 폰트** | 게임 테마가 `*` 에 `!important` 로 도트 폰트를 강제하는데, 아이콘까지 걸리면 리거처가 풀려 "mic" 같은 글자가 그대로 보인다 |

## 반응형

**데스크톱과 모바일이 같은 프로젝트 · 같은 라우트 · 같은 컴포넌트다.**
레이아웃만 폭에 따라 갈린다.

| 폭 | 네비게이션 |
|---|---|
| < 720px | 하단 탭바 (아이콘 + 라벨), 상단은 브랜드만 |
| ≥ 720px | 상단 네비, 탭바 숨김 |

상단에 라벨을 다 넣으면 좁은 폭에서 글자가 두 줄로 접힌다.
하단 탭바는 `env(safe-area-inset-bottom)` 으로 아이폰 홈 인디케이터를 피한다.

## 접근성

| 항목 | 처리 |
|---|---|
| 모션 | `prefers-reduced-motion` **및** `data-reduce-motion` 둘 다 존중 |
| 블러 | `data-reduce-blur` 로 끌 수 있음 |
| 터치 타깃 | 최소 44px (`--control-height`) |
| 색 의존 | 색만으로 정보를 전달하지 않는다 (화자·상태 모두 라벨 병기) |
| 녹음 상태 | `aria-live` 로 변화를 알린다 |

## 이식하지 않은 것

- **수채화**(`wc-cool` / `wc-warm`) — 이번 범위 밖. 필요하면 devkanban `media.css` 에서 가져온다
- `light-cool` / `dark-cool` / `custom` — 온도 변형은 나중에
- 태스크 상태 색, 에이전트 그라디언트 — 이 앱에 없는 개념
