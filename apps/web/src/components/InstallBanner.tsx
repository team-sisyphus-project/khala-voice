import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { isStandalone, onInstallAvailability, promptInstall } from "@/lib/pwa";
import { Icon } from "@/ui";

const DISMISSED_KEY = "vr:install-dismissed";

/**
 * 홈 화면에 추가 안내.
 *
 * ## 한 번 닫으면 다시 묻지 않는다
 *
 * 설치 배너는 쉽게 성가셔진다. 닫은 사실을 남겨 두고,
 * 사용자가 원하면 설정에서 다시 열 수 있게 한다.
 *
 * iOS Safari 는 `beforeinstallprompt` 를 지원하지 않아 이 배너가 뜨지 않는다.
 * 대신 설정 화면에 수동 안내를 둔다.
 */
export function InstallBanner() {
  const { t } = useTranslation();
  const [available, setAvailable] = useState(false);
  const [dismissed, setDismissed] = useState(
    () => localStorage.getItem(DISMISSED_KEY) === "true",
  );

  useEffect(() => onInstallAvailability(setAvailable), []);

  if (!available || dismissed || isStandalone()) return null;

  return (
    <div className="vr-install" role="region" aria-label={t("install.regionAria")}>
      <Icon name="install_mobile" />

      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 600, fontSize: 14 }}>{t("install.title")}</div>
        <div className="vr-note vr-note--small">
          {t("install.desc")}
        </div>
      </div>

      <button
        className="mobile-button mobile-button--primary mobile-button--fit"
        onClick={() => void promptInstall()}
      >
        {t("install.add")}
      </button>

      <button
        className="mobile-button mobile-button--ghost mobile-button--fit"
        aria-label={t("common.close")}
        onClick={() => {
          localStorage.setItem(DISMISSED_KEY, "true");
          setDismissed(true);
        }}
      >
        <Icon name="close" />
      </button>
    </div>
  );
}
