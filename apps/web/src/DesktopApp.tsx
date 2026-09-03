import { Navigate, Route, Routes } from "react-router";

/**
 * The desktop surface (`/app/*`) — three-pane layout.
 *
 * Its **information architecture differs** from mobile: the mobile meetings
 * tab is "record now", while desktop views list and detail side by side. So
 * instead of stretching the same components by width, the surfaces are split
 * (`lib/surface.ts`).
 *
 * **Still under construction.** Meanwhile, people arriving on desktop must
 * not hit a wall, so they're sent to the mobile surface — built for narrow
 * screens, but fully functional.
 */
export function DesktopApp() {
  return (
    <Routes>
      <Route path="*" element={<ToMobile />} />
    </Routes>
  );
}

function ToMobile() {
  // `/app/meetings/1` → `/m/meetings/1`. The rest is unchanged, so it maps 1:1.
  const rest = window.location.pathname.replace(/^\/app/, "");
  return <Navigate to={`/m${rest}${window.location.search}`} replace />;
}
