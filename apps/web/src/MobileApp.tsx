import { Navigate, Route, Routes } from "react-router";
import { MeetingsPage } from "@/routes/MeetingsPage";
import { MeetingDetailPage } from "@/routes/MeetingDetailPage";
import { ArchivePage } from "@/routes/ArchivePage";
import { TaxonomyPage } from "@/routes/TaxonomyPage";
import { BillingPage } from "@/routes/BillingPage";
import { AppSettingsPage } from "@/routes/AppSettingsPage";

/**
 * 모바일 표면(`/m/*`).
 *
 * 한 화면씩 보여주고 하단 탭으로 옮겨 다닌다. 디자인은 devkanban 모바일 그대로다.
 * 데스크톱 표면은 [`DesktopApp`](./DesktopApp.tsx) 이 맡는다 — 정보 구조가 달라
 * 같은 컴포넌트를 폭으로 늘리지 않는다 (`lib/surface.ts` 참조).
 */
export function MobileApp() {
  return (
    <Routes>
      <Route index element={<Navigate to="meetings" replace />} />
      <Route path="meetings" element={<MeetingsPage />} />
      <Route path="meetings/:id" element={<MeetingDetailPage />} />
      <Route path="archive" element={<ArchivePage />} />
      <Route path="taxonomy" element={<TaxonomyPage />} />
      <Route path="billing" element={<BillingPage />} />
      <Route path="settings" element={<AppSettingsPage />} />
      <Route path="*" element={<Navigate to="meetings" replace />} />
    </Routes>
  );
}
