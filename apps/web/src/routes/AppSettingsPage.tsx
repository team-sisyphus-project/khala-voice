import { useEffect, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { Link } from "react-router";
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

/**
 * 설정 — iOS 설정 앱 문법.
 *
 * 묶음마다 작은 제목이 붙고, 그 아래 카드 하나에 행이 쌓인다. 한 카드에 여러
 * 성격을 몰아넣지 않는다 — "이건 화면 이야기, 저건 녹음 이야기"가 제목으로 갈린다.
 *
 * ## 무엇이 여기 있고 무엇이 계정 설정에 있나
 *
 * | 여기 (이 기기) | 계정 설정 (`/settings`) |
 * |---|---|
 * | 테마 · 녹음 기본값 · 알림 · 홈 화면 추가 | 프로필 · 비밀번호 · 로그인된 기기 · 계정 삭제 |
 *
 * 테마는 계정에 저장되지만 **고르는 자리는 여기**다. 화면 모양을 바꾸려고
 * 계정 설정까지 들어가는 것은 iOS 문법이 아니다.
 */
export function AppSettingsPage() {
  const { t } = useTranslation();
  const routes = useRoutes();
  const [prefs, setPrefs] = usePrefs();
  const { account, setAccount } = useAccount();
  const [theme, setTheme] = useState<Theme>(cachedTheme);
  const [installable, setInstallable] = useState(false);
  const [editingPrefs, setEditingPrefs] = useState(false);
  const standalone = isStandalone();

  useEffect(() => onInstallAvailability(setInstallable), []);

  async function pickTheme(next: Theme) {
    // 화면을 먼저 바꾸고 저장은 뒤따른다. 실패해도 화면은 바뀐 채로 둔다.
    setTheme(next);
    await applyTheme(next);
  }

  return (
    <AppShell active="settings" title={t("settings.title")}>
      <Section title={t("settings.displaySection")} card>
        <div className="vr-theme-grid">
          {THEMES.map((item) => (
            <button
              key={item.id}
              type="button"
              className="vr-theme"
              data-active={theme === item.id ? "true" : undefined}
              onClick={() => void pickTheme(item.id)}
            >
              <Icon name={item.icon} />
              <span>{item.label}</span>
            </button>
          ))}
        </div>

        {/* UI 언어는 계정에 있다(`locale`) — 기기를 바꿔도 따라온다. 전사 언어와 별개다. */}
        <LocaleField account={account} onChange={setAccount} />
      </Section>

      <Section title={t("settings.recordingSection")} card>
        <Row
          title={t("settings.microphone")}
          meta={prefs.micDeviceId ? t("settings.micSelected") : t("settings.micDefault")}
          chevron
          onClick={() => setEditingPrefs(true)}
        />
        <p className="vr-note vr-note--small">
          <Trans t={t} i18nKey="settings.micNote" components={{ strong: <strong /> }} />
        </p>

        {/* 언어는 계정에 있다 — 기기를 바꿔도 따라온다 */}
        <LanguageField account={account} onChange={setAccount} />
      </Section>

      {/* 카드 안이 "작업 완료 알림"이라 그룹 제목이 같은 말을 두 번 한다. */}
      <Section card>
        <NotificationSetting />
      </Section>

      <Section card>
        <Link className="vr-nav-row" to={routes.billing}>
          <span className="vr-nav-row__title">{t("settings.creditsTitle")}</span>
          <span className="vr-nav-row__meta">{t("settings.creditsMeta")}</span>
          <Icon name="chevron_right" />
        </Link>
      </Section>

      <IntegrationsSection />

      <Section card>
        <a className="vr-nav-row" href={routes.account}>
          <span className="vr-nav-row__title">{t("settings.accountTitle")}</span>
          <span className="vr-nav-row__meta">{t("settings.accountMeta")}</span>
          <Icon name="chevron_right" />
        </a>
      </Section>

      <Section title={t("settings.installSection")} card>
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
          /* iOS Safari 는 beforeinstallprompt 를 지원하지 않는다.
             버튼을 띄울 수 없으니 손으로 하는 방법을 적어 둔다. */
          <ol className="vr-note vr-note--small" style={{ margin: 0, paddingLeft: 18, lineHeight: 1.8 }}>
            <li>
              <Trans
                t={t}
                i18nKey="settings.installIos"
                components={{ strong: <strong />, icon: <Icon name="ios_share" /> }}
              />
            </li>
            <li>
              <Trans t={t} i18nKey="settings.installAndroid" components={{ strong: <strong /> }} />
            </li>
            <li>
              <Trans t={t} i18nKey="settings.installDesktop" components={{ strong: <strong /> }} />
            </li>
          </ol>
        )}
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
