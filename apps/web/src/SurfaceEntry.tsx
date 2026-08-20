import { Navigate, useLocation } from "react-router";
import { entrySurface, toSurface } from "@/lib/surface";

/**
 * 표면을 정하지 않은 진입을 정한 표면으로 보낸다.
 *
 * 두 가지 자리에서 쓴다:
 *
 * 1. `/`, `/app`, `/m` — 화면을 특정하지 않은 진입
 * 2. `/go/*` — **표면 중립 딥링크.** 서버(푸시 알림 · 메일 · 워커)가 만드는
 *    링크는 받는 사람이 폰인지 데스크톱인지 모른다. `/go/meetings/123` 하나로
 *    보내면 여는 쪽에서 표면을 고른다
 *
 * 이미 표면이 붙은 딥링크(`/m/meetings/123`)는 **받은 그대로** 연다.
 * 폭으로 뒤집으면 남에게 받은 링크가 다른 화면을 열게 된다.
 */
export function SurfaceEntry() {
  const { pathname, search } = useLocation();
  const surface = entrySurface();

  return <Navigate to={`${toSurface(pathname, surface)}${search}`} replace />;
}
