import { Navigate, Route, Routes } from "react-router";

/**
 * 데스크톱 표면(`/app/*`) — 3단 레이아웃.
 *
 * 모바일과 **정보 구조가 다르다**: 모바일의 회의 탭은 "즉시 녹음"이지만
 * 데스크톱은 목록과 상세를 나란히 본다. 그래서 같은 컴포넌트를 폭으로 늘리지
 * 않고 표면을 나눴다 (`lib/surface.ts`).
 *
 * **아직 만드는 중이다.** 그동안 데스크톱으로 들어온 사람이 막히면 안 되니
 * 모바일 표면으로 보낸다 — 좁은 화면용이지만 기능은 전부 동작한다.
 */
export function DesktopApp() {
  return (
    <Routes>
      <Route path="*" element={<ToMobile />} />
    </Routes>
  );
}

function ToMobile() {
  // `/app/meetings/1` → `/m/meetings/1`. 뒤는 그대로라 1:1 로 옮겨진다.
  const rest = window.location.pathname.replace(/^\/app/, "");
  return <Navigate to={`/m${rest}${window.location.search}`} replace />;
}
