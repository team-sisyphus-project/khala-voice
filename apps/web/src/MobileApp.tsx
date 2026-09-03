import { Navigate, Route, Routes } from "react-router";
import { MeetingsPage } from "@/routes/MeetingsPage";
import { MeetingDetailPage } from "@/routes/MeetingDetailPage";
import { ArchivePage } from "@/routes/ArchivePage";
import { TaxonomyPage } from "@/routes/TaxonomyPage";
import { BillingPage } from "@/routes/BillingPage";
import { AppSettingsPage } from "@/routes/AppSettingsPage";

/**
 * The mobile surface (`/m/*`).
 *
 * One screen at a time, moving via the bottom tabs. The design is devkanban
 * mobile as-is. The desktop surface is [`DesktopApp`](./DesktopApp.tsx)'s job
 * — its information architecture differs, so the same components aren't
 * stretched by width (see `lib/surface.ts`).
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
