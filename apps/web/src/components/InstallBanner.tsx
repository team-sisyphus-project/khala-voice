import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { isStandalone, onInstallAvailability, promptInstall } from "@/lib/pwa";
import { Icon } from "@/ui";

const DISMISSED_KEY = "vr:install-dismissed";

/**
 * The add-to-home-screen prompt.
 *
 * ## Once dismissed, never asks again
 *
 * Install banners get annoying fast. Record the dismissal, and let the user
 * reopen it from settings if they want.
 *
 * iOS Safari doesn't support `beforeinstallprompt`, so this banner never
 * shows there. The settings screen carries manual instructions instead.
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
