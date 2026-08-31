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

// 설치 프롬프트는 앱이 뜨기 전에 올 수 있다. 리스너를 먼저 건다.
watchInstallPrompt();
registerServiceWorker();

// 누름 반응(`styles/devkanban/press.css`)은 이 리스너가 `data-pressed` 를 걸어야
// 살아난다. 빼먹으면 버튼이 눌려도 아무 일도 일어나지 않는다 — devkanban 에서
// 가져오려던 것의 절반이 이것이다.
installPressFeedback();

const root = document.getElementById("root");
if (!root) throw new Error("#root 를 찾을 수 없습니다");

createRoot(root).render(
  <StrictMode>
    <I18nextProvider i18n={i18n}>
      <IntroScreen>
        <BrowserRouter>
          <Routes>
          {/* 표면을 정하지 않은 진입 — 폭(또는 사용자가 고른 값)으로 고른다 */}
          <Route path="/" element={<SurfaceEntry />} />
          <Route path="/app" element={<SurfaceEntry />} />
          <Route path="/m" element={<SurfaceEntry />} />

          {/* 표면 중립 딥링크 — 푸시·메일·워커가 만드는 링크는 여기로 온다.
              받는 기기가 폰인지 데스크톱인지 서버는 모른다. */}
          <Route path="/go/*" element={<SurfaceEntry />} />

          <Route path="/m/*" element={<MobileApp />} />
          <Route path="/app/*" element={<DesktopApp />} />

          {/* 공유 뷰는 두 표면 **바깥**이다. 그래서 남에게 보내는 링크는 한 종류다. */}
          <Route path="/share/:token" element={<SharePage />} />

          <Route path="*" element={<SurfaceEntry />} />
          </Routes>
        </BrowserRouter>
      </IntroScreen>
    </I18nextProvider>
  </StrictMode>,
);
