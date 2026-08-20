# devkanban 모바일 스타일 — 그대로 가져온 것

**출처: devkanban** `mobile/src/styles/`.

버튼의 누름 반응 · 헤더 표현 · 인풋 · 모달 · 글래스모피즘 표면을 그대로 쓰기 위해
**손대지 않고 복사**했다. 우리 화면에 없는 devkanban 전용 규칙(칸반 보드 · 채팅 ·
워크플랜)도 함께 딸려 온다 — 규칙을 골라내다 캐스케이드를 깨뜨리는 것보다
그대로 두는 편이 안전하다.

| 파일 | 무엇 |
|---|---|
| `tokens.css` | 디자인 토큰 · 테마 정의(light/dark/cool/wc/pencil/game) |
| `base.css` | 리셋과 문서 기본 |
| `components.css` | 컴포넌트 기본 규칙 |
| `redesign.css` | 그 위를 덮는 현재 디자인. **components.css 뒤에 와야 한다** |
| `press.css` | 누름 반응. 컴포넌트가 각자 갖던 `:active` 를 시스템 규칙 하나로 덮는다. **맨 마지막** |
| `game-skin.css` | 게임 테마. press.css 뒤 — 누름 문법이 반대라(아래로 눌린다) 순서로 이긴다 |

## 고치지 말 것

이 디렉터리의 파일은 **원본과 같아야 한다.** 우리 쪽 조정이 필요하면
`apps/web/src/styles/overrides.css` 에 따로 쓴다. 여기에 손대면 devkanban 이
디자인을 고쳤을 때 무엇이 우리 것이고 무엇이 원본인지 구분할 수 없어진다.

원본 위치: `devkanban/mobile/src/styles/`
가져온 날: 2026-08-20
