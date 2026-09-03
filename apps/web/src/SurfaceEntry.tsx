import { Navigate, useLocation } from "react-router";
import { entrySurface, toSurface } from "@/lib/surface";

/**
 * Sends surface-undecided entries to a decided surface.
 *
 * Used in two places:
 *
 * 1. `/`, `/app`, `/m` — entries that don't name a screen
 * 2. `/go/*` — **surface-neutral deep links.** Links built by the server
 *    (push notifications · mail · workers) can't know whether the recipient
 *    is on a phone or a desktop. Send one `/go/meetings/123` and the opening
 *    side picks the surface
 *
 * A deep link that already carries a surface (`/m/meetings/123`) opens
 * **exactly as received**. Flipping it by width would make a link received
 * from someone else open a different screen.
 */
export function SurfaceEntry() {
  const { pathname, search } = useLocation();
  const surface = entrySurface();

  return <Navigate to={`${toSurface(pathname, surface)}${search}`} replace />;
}
