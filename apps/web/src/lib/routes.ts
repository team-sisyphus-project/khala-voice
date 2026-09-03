/**
 * Screen addresses are built **in one place**.
 *
 * Strings like `/app/meetings` used to be scattered across 20 files. The
 * moment the surfaces split (`/app` desktop · `/m` mobile), every one of them
 * became a wrong address.
 *
 * Screen code doesn't need to know which surface it runs on — `useRoutes()`
 * reads the prefix off the current address and prepends it.
 */

import { useLocation } from "react-router";
import { surfaceOf } from "./surface";
import type { Surface } from "./surface";

export interface Routes {
  surface: Surface;
  meetings: string;
  meeting: (id: string) => string;
  archive: string;
  taxonomy: string;
  billing: string;
  settings: string;
  /** Account settings is LiveView, so it has no surface prefix */
  account: string;
  friends: string;
}

export function routesFor(surface: Surface): Routes {
  const base = `/${surface}`;

  return {
    surface,
    meetings: `${base}/meetings`,
    meeting: (id: string) => `${base}/meetings/${encodeURIComponent(id)}`,
    archive: `${base}/archive`,
    taxonomy: `${base}/taxonomy`,
    billing: `${base}/billing`,
    settings: `${base}/settings`,
    account: "/settings",
    friends: "/friends",
  };
}

export function useRoutes(): Routes {
  const { pathname } = useLocation();
  return routesFor(surfaceOf(pathname) ?? "m");
}
