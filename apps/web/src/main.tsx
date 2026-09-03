import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, Route, Routes } from "react-router";
import { I18nextProvider } from "react-i18next";
import i18n from "@/i18n";
import { MobileApp } from "@/MobileApp";
import { DesktopApp } from "@/DesktopApp";
import { SurfaceEntry } from "@/SurfaceEntry";
import { SharePage } from "@/routes/SharePage";
import { IntroScreen } from "@/components/IntroScreen";
import { registerServiceWorker, watchInstallPrompt } from "@/lib/pwa";
import { installPressFeedback } from "@/ui/press";
import "./styles/app.css";

// The install prompt can arrive before the app is up. Attach the listener first.
watchInstallPrompt();
registerServiceWorker();

// Press feedback (`styles/devkanban/press.css`) only comes alive when this
// listener sets `data-pressed`. Leave it out and pressing a button does
// nothing visible — half of what we wanted from devkanban is this.
installPressFeedback();

const root = document.getElementById("root");
if (!root) throw new Error("Root element #root not found");

createRoot(root).render(
  <StrictMode>
    <I18nextProvider i18n={i18n}>
      <IntroScreen>
        <BrowserRouter>
          <Routes>
          {/* An entry with no surface decided — chosen by width (or the user's saved pick) */}
          <Route path="/" element={<SurfaceEntry />} />
          <Route path="/app" element={<SurfaceEntry />} />
          <Route path="/m" element={<SurfaceEntry />} />

          {/* Surface-neutral deep links — links built by push, mail, and workers
              come here. The server can't know if the receiving device is a phone
              or a desktop. */}
          <Route path="/go/*" element={<SurfaceEntry />} />

          <Route path="/m/*" element={<MobileApp />} />
          <Route path="/app/*" element={<DesktopApp />} />

          {/* The share view lives **outside** both surfaces. So there's only one kind of link to send to others. */}
          <Route path="/share/:token" element={<SharePage />} />

          <Route path="*" element={<SurfaceEntry />} />
          </Routes>
        </BrowserRouter>
      </IntroScreen>
    </I18nextProvider>
  </StrictMode>,
);
