/**
 * 화면 주소를 **한 곳에서** 만든다.
 *
 * 예전에는 `/app/meetings` 같은 문자열이 20개 파일에 흩어져 있었다. 표면을
 * 나누는 순간(`/app` 데스크톱 · `/m` 모바일) 그게 전부 틀린 주소가 된다.
 *
 * 화면 코드는 자기가 어느 표면에서 도는지 몰라도 된다 — `useRoutes()` 가
 * 지금 주소에서 접두어를 읽어 붙인다.
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
  /** 계정 설정은 LiveView 라 표면 접두어가 없다 */
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
