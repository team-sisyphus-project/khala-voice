/**
 * Screen surfaces — desktop and mobile split **by path**.
 *
 *     /app/*  desktop (three panes)
 *     /m/*    mobile (one screen at a time)
 *
 * ## Why split by path
 *
 * The desktop three-pane and mobile single-screen layouts are not the same
 * screen at different widths — their **information architecture differs**: the
 * mobile meetings tab is "record now", while desktop is "list + detail". And
 * the devkanban mobile CSS we use has no desktop breakpoints at all (only
 * `max-width`). Absorbing it responsively would mean writing a second design
 * layer anyway.
 *
 * ## Why share links don't split
 *
 * `/share/:token` and `/invite/:token` live **outside both surfaces**, so even
 * with split surfaces there is only one kind of link to send to others. (This
 * was the docs' argument against a `/m/` split, and it doesn't apply to the
 * current structure — `docs/08-frontend.md`.)
 *
 * ## Link portability
 *
 * Only the prefix differs; **the rest is identical.** `/m/meetings/123` and
 * `/app/meetings/123` map 1:1, so a link from either side opens. Automatic
 * switching happens **only on first entry** — deep links open exactly as
 * received.
 */

export type Surface = "app" | "m";

const PREFERENCE_KEY = "vr:surface";

/** Below this width is mobile. The devkanban mobile body is 520px, so leave headroom above it. */
const DESKTOP_MIN_WIDTH = 900;

export const SURFACES: Surface[] = ["app", "m"];

/** Which surface the current address is on. null if neither. */
export function surfaceOf(pathname: string): Surface | null {
  if (pathname === "/app" || pathname.startsWith("/app/")) return "app";
  if (pathname === "/m" || pathname.startsWith("/m/")) return "m";
  return null;
}

/**
 * The remainder after stripping the surface (or the neutral `/go` prefix).
 *
 *     /m/meetings/1    → /meetings/1
 *     /go/meetings/1   → /meetings/1
 *     /app             → /meetings   (an empty rest goes to the first screen)
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

/** The same screen's address on the other surface. `/m/meetings/1` ↔ `/app/meetings/1` is 1:1. */
export function toSurface(pathname: string, surface: Surface): string {
  return `/${surface}${withoutSurface(pathname)}`;
}

/** The default surface chosen by viewport width. */
export function surfaceForViewport(): Surface {
  if (typeof window === "undefined") return "m";
  return window.innerWidth >= DESKTOP_MIN_WIDTH ? "app" : "m";
}

/**
 * The surface the user picked explicitly. null if none.
 *
 * Once picked, width never overrides it again — if the choice to view desktop
 * in a narrow window were reverted every time, there would be no way to reach
 * that screen.
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
    // Even if it can't be saved, it still applies for this session
  }
}

/**
 * The surface for first entry. **Not used for deep links.**
 *
 * Called only for entries that don't name a screen, like `/`, `/app`, `/m`.
 * Flipping a deep link like `/m/meetings/123` by width would make a received
 * link open a different screen.
 */
export function entrySurface(): Surface {
  return preferredSurface() ?? surfaceForViewport();
}
