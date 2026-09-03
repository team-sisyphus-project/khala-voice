import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router";
import { api } from "@/lib/api";
import { AppShell } from "@/components/AppShell";
import { NotificationSetting } from "@/components/NotificationSetting";
import { IntegrationsSection } from "@/components/IntegrationsSection";
import { RecordingPrefsSheet } from "@/components/RecordingPrefsSheet";
import { Notice } from "@/components/ui";
import { usePrefs } from "@/hooks/usePrefs";
import { useAccount } from "@/hooks/useAccount";
import { LanguageField } from "@/components/LanguageField";
import { LocaleField } from "@/components/LocaleField";
import { useRoutes } from "@/lib/routes";
import { isStandalone, onInstallAvailability, promptInstall } from "@/lib/pwa";
import { applyTheme, cachedTheme, THEMES } from "@/lib/theme";
import type { Theme } from "@/lib/theme";
import { Button, Icon, Row, Section } from "@/ui";
import { SETTINGS_SECTIONS } from "./settingsStructure";
import type { SettingItem } from "./settingsStructure";

/**
 * Settings — iOS Settings-app grammar.
 *
 * Each group gets a small title, with rows stacked in one card below it. Don't
 * cram unrelated concerns into one card — "this is about display, that's about
 * recording" is what the titles separate.
 *
 * ## What lives here vs. in account settings
 *
 * | Here (this device) | Account settings (`/settings`) |
 * |---|---|
 * | Theme · recording defaults · notifications · add to home screen | Profile · password · signed-in devices · account deletion |
 *
 * The theme is stored on the account, but **it's picked here**. Making people
 * dig into account settings to change how the screen looks is not iOS grammar.
 */
export function AppSettingsPage() {
  const { t } = useTranslation();
  const routes = useRoutes();
  const [prefs, setPrefs] = usePrefs();
  const { account, setAccount } = useAccount();
  const [theme, setTheme] = useState<Theme>(cachedTheme);
  const [installable, setInstallable] = useState(false);
  const [editingPrefs, setEditingPrefs] = useState(false);
  const [loggingOut, setLoggingOut] = useState(false);

  async function logout() {
    setLoggingOut(true);

    try {
      await api.logout();
    } finally {
      // Send to the login screen even on failure — the server session may already
      // be gone, and staying on this screen leaves it unclear what works and what doesn't.
      // A real navigation, not the SPA router: it throws away all remaining state.
      window.location.href = "/login";
    }
  }
  const standalone = isStandalone();

  useEffect(() => onInstallAvailability(setInstallable), []);

  async function pickTheme(next: Theme) {
    // Change the screen first; saving follows. On failure, leave the screen changed.
    setTheme(next);
    await applyTheme(next);
  }

  function renderSetting(item: SettingItem) {
    switch (item) {
      case "theme":
        return (
          <div className="vr-settings-subgroup" data-setting-group={item}>
            <h3 className="vr-settings-subgroup__title">Theme</h3>
            <div className="vr-theme-grid">
              {THEMES.map((themeItem) => (
                <button
                  key={themeItem.id}
                  type="button"
                  className="vr-theme"
                  data-active={theme === themeItem.id ? "true" : undefined}
                  onClick={() => void pickTheme(themeItem.id)}
                >
                  <Icon name={themeItem.icon} />
                  <span>{t(`theme.${themeItem.id}`)}</span>
                </button>
              ))}
            </div>

            {/* The UI language lives on the account (`locale`) — it follows across devices. Separate from the transcription language. */}
            <LocaleField account={account} onChange={setAccount} />
          </div>
        );

      case "install":
        return (
          <div className="vr-settings-subgroup" data-setting-group={item}>
            <h3 className="vr-settings-subgroup__title">{t("settings.installSection")}</h3>
            {standalone ? (
              <Notice kind="ok" icon="check_circle">
                {t("settings.installedAlready")}
              </Notice>
            ) : installable ? (
              <>
                <p className="vr-note vr-note--small">
                  {t("settings.installBenefit")}
                </p>
                <Button full onClick={() => void promptInstall()}>
                  {t("settings.installNow")}
                </Button>
              </>
            ) : (
              <ol className="vr-note vr-note--small vr-install-guide">
                <li>
                  <strong>iPhone · iPad</strong> — Share button (<Icon name="ios_share" />) →
                  &ldquo;Add to Home Screen&rdquo;
                </li>
                <li>
                  <strong>Android</strong> — Menu (⋮) → &ldquo;Add to Home Screen&rdquo;
                </li>
                <li>
                  <strong>Desktop</strong> — install icon on the right of the address bar
                </li>
              </ol>
            )}
          </div>
        );

      case "microphone-and-language":
        return (
          <div className="vr-settings-subgroup" data-setting-group={item}>
            <Row
              title={t("settings.microphone")}
              meta={prefs.micDeviceId ? t("settings.micSelected") : t("settings.micDefault")}
              chevron
              onClick={() => setEditingPrefs(true)}
            />
            <p className="vr-note vr-note--small">
              The microphone applies <strong>to this device only</strong>. The meeting-room
              PC and your phone each use their own microphone.
            </p>
            <LanguageField account={account} onChange={setAccount} />
          </div>
        );

      case "completion-notification":
        return (
          <div className="vr-settings-subgroup" data-setting-group={item}>
            <NotificationSetting />
          </div>
        );

      case "billing":
        return (
          <div className="vr-settings-subgroup" data-setting-group={item}>
            <Link className="vr-nav-row" to={routes.billing}>
              <span className="vr-nav-row__title">{t("settings.creditsTitle")}</span>
              <span className="vr-nav-row__meta">{t("settings.creditsMeta")}</span>
              <Icon name="chevron_right" />
            </Link>
          </div>
        );

      case "integrations":
        return (
          <div className="vr-settings-subgroup" data-setting-group={item}>
            <IntegrationsSection />
          </div>
        );

      case "account":
        return (
          <div className="vr-settings-subgroup" data-setting-group={item}>
            <a className="vr-nav-row" href={routes.account}>
              <span className="vr-nav-row__title">{t("settings.accountTitle")}</span>
              <span className="vr-nav-row__meta">{t("settings.accountMeta")}</span>
              <Icon name="chevron_right" />
            </a>
          </div>
        );
    }
  }

  return (
    <AppShell active="settings" title={t("settings.title")}>
      {SETTINGS_SECTIONS.map((section) => (
        <Section key={section.id} title={section.title} card className="vr-settings-section">
          {section.items.map((item) => (
            <div key={item}>{renderSetting(item)}</div>
          ))}
        </Section>
      ))}

      {/* Log out sits at the **very bottom**. iOS Settings grammar, and a spot that's hard to press by accident. */}
      <Section card>
        <Button variant="danger" full icon="logout" onClick={() => void logout()} pending={loggingOut}>
          Log out
        </Button>
        <p className="vr-note vr-note--small">
          Signs you out on this device only. Disconnect other devices in{" "}
          <a href={routes.account}>account settings</a>.
        </p>
      </Section>

      {editingPrefs && (
        <RecordingPrefsSheet
          micDeviceId={prefs.micDeviceId}
          account={account}
          onMicChange={(micDeviceId) => setPrefs({ micDeviceId })}
          onAccountChange={setAccount}
          onClose={() => setEditingPrefs(false)}
        />
      )}
    </AppShell>
  );
}
