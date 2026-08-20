/**
 * 화면 표면(surface) — 데스크톱과 모바일을 **경로로** 가른다.
 *
 *     /app/*  데스크톱 (3단)
 *     /m/*    모바일 (한 화면씩)
 *
 * ## 왜 경로로 가르나
 *
 * 데스크톱 3단과 모바일 한 화면은 같은 화면의 다른 폭이 아니라 **정보 구조가
 * 다르다** — 모바일의 회의 탭은 "즉시 녹음"이고 데스크톱은 "목록 + 상세"다.
 * 그리고 우리가 쓰는 devkanban 모바일 CSS 에는 데스크톱 브레이크포인트가
 * 하나도 없다(전부 `max-width` 뿐). 반응형으로 흡수하려면 어차피 두 번째
 * 디자인 층을 새로 써야 한다.
 *
 * ## 공유 링크는 왜 안 나뉘나
 *
 * `/share/:token` 과 `/invite/:token` 은 **두 표면 바깥**에 있다. 그래서
 * 표면을 나눠도 남에게 보내는 링크는 한 종류다. (문서가 `/m/` 분리를 반대했던
 * 근거가 이것이었는데, 지금 구조에서는 걸리지 않는다 — `docs/08-frontend.md`)
 *
 * ## 링크 이식성
 *
 * 접두어만 다르고 **뒤는 같다.** `/m/meetings/123` 과 `/app/meetings/123` 은
 * 1:1 로 옮겨진다. 그래서 어느 쪽 링크를 받아도 열린다 — 자동 전환은
 * **첫 진입에서만** 하고, 딥링크는 받은 그대로 연다.
 */

export type Surface = "app" | "m";

const PREFERENCE_KEY = "vr:surface";

/** 이 폭 아래는 모바일. devkanban 모바일 본문이 520px 라 그 위로 여유를 둔다. */
const DESKTOP_MIN_WIDTH = 900;

export const SURFACES: Surface[] = ["app", "m"];

/** 지금 주소가 어느 표면인가. 둘 다 아니면 null. */
export function surfaceOf(pathname: string): Surface | null {
  if (pathname === "/app" || pathname.startsWith("/app/")) return "app";
  if (pathname === "/m" || pathname.startsWith("/m/")) return "m";
  return null;
}

/**
 * 표면(또는 중립 접두어 `/go`)을 뗀 나머지.
 *
 *     /m/meetings/1    → /meetings/1
 *     /go/meetings/1   → /meetings/1
 *     /app             → /meetings   (뒤가 비면 첫 화면으로)
 *     /                → /meetings
 */
export function withoutSurface(pathname: string): string {
  for (const prefix of ["/app", "/m", "/go"]) {
    if (pathname === prefix) return "/meetings";
    if (pathname.startsWith(`${prefix}/`)) {
      const rest = pathname.slice(prefix.length);
      return rest === "/" ? "/meetings" : rest;
    }
  }

  return pathname === "/" ? "/meetings" : pathname;
}

/** 같은 화면의 다른 표면 주소. `/m/meetings/1` ↔ `/app/meetings/1` 은 1:1 이다. */
export function toSurface(pathname: string, surface: Surface): string {
  return `/${surface}${withoutSurface(pathname)}`;
}

/** 폭으로 고른 기본 표면. */
export function surfaceForViewport(): Surface {
  if (typeof window === "undefined") return "m";
  return window.innerWidth >= DESKTOP_MIN_WIDTH ? "app" : "m";
}

/**
 * 사용자가 직접 고른 표면. 없으면 null.
 *
 * 한 번 고르면 폭으로 다시 뒤집지 않는다 — 좁은 창에서 데스크톱을 보겠다는
 * 선택을 매번 되돌리면 그 화면에 갈 방법이 없다.
 */
export function preferredSurface(): Surface | null {
  try {
    const stored = localStorage.getItem(PREFERENCE_KEY);
    return stored === "app" || stored === "m" ? stored : null;
  } catch {
    return null;
  }
}

export function rememberSurface(surface: Surface): void {
  try {
    localStorage.setItem(PREFERENCE_KEY, surface);
  } catch {
    // 저장 못 해도 이번 세션에는 적용된다
  }
}

/**
 * 첫 진입에서 갈 표면. **딥링크에는 쓰지 않는다.**
 *
 * `/`, `/app`, `/m` 처럼 화면을 특정하지 않은 진입에서만 부른다.
 * `/m/meetings/123` 같은 딥링크를 폭으로 뒤집으면 받은 링크가 다른 화면을 연다.
 */
export function entrySurface(): Surface {
  return preferredSurface() ?? surfaceForViewport();
}
