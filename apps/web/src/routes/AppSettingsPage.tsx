import { useEffect, useState } from "react";
import { Link } from "react-router";
import { AppShell } from "@/components/AppShell";
import { NotificationSetting } from "@/components/NotificationSetting";
import { IntegrationsSection } from "@/components/IntegrationsSection";
import { RecordingPrefsSheet } from "@/components/RecordingPrefsSheet";
import { Notice } from "@/components/ui";
import { usePrefs } from "@/hooks/usePrefs";
import { useAccount } from "@/hooks/useAccount";
import { LanguageField } from "@/components/LanguageField";
import { useRoutes } from "@/lib/routes";
import { isStandalone, onInstallAvailability, promptInstall } from "@/lib/pwa";
import { applyTheme, cachedTheme, THEMES } from "@/lib/theme";
import type { Theme } from "@/lib/theme";
import { Button, Icon, Row, Section } from "@/ui";
import { SETTINGS_SECTIONS } from "./settingsStructure";
import type { SettingItem } from "./settingsStructure";

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

  function renderSetting(item: SettingItem) {
    switch (item) {
      case "theme":
        return (
          <div className="vr-settings-subgroup" data-setting-group={item}>
            <h3 className="vr-settings-subgroup__title">테마</h3>
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
                  <span>{themeItem.label}</span>
                </button>
              ))}
            </div>
          </div>
        );

      case "install":
        return (
          <div className="vr-settings-subgroup" data-setting-group={item}>
            <h3 className="vr-settings-subgroup__title">홈 화면에 추가</h3>
            {standalone ? (
              <Notice kind="ok" icon="check_circle">
                이미 앱으로 실행 중입니다.
              </Notice>
            ) : installable ? (
              <>
                <p className="vr-note vr-note--small">
                  주소창 없이 열리고, 녹음 화면으로 바로 들어갑니다.
                </p>
                <Button full onClick={() => void promptInstall()}>
                  지금 추가
                </Button>
              </>
            ) : (
              <ol className="vr-note vr-note--small vr-install-guide">
                <li>
                  <strong>iPhone · iPad</strong> — 공유 버튼(<Icon name="ios_share" />) →
                  &ldquo;홈 화면에 추가&rdquo;
                </li>
                <li>
                  <strong>Android</strong> — 메뉴(⋮) → &ldquo;홈 화면에 추가&rdquo;
                </li>
                <li>
                  <strong>데스크톱</strong> — 주소창 오른쪽 설치 아이콘
                </li>
              </ol>
            )}
          </div>
        );

      case "microphone-and-language":
        return (
          <div className="vr-settings-subgroup" data-setting-group={item}>
            <Row
              title="마이크"
              meta={prefs.micDeviceId ? "고른 장치" : "기본 장치"}
              chevron
              onClick={() => setEditingPrefs(true)}
            />
            <p className="vr-note vr-note--small">
              마이크는 <strong>이 기기에서만</strong> 적용됩니다. 회의실 PC 와 폰은 각자
              다른 마이크를 씁니다.
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
              <span className="vr-nav-row__title">크레딧 보기</span>
              <span className="vr-nav-row__meta">잔액과 사용 내역</span>
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
              <span className="vr-nav-row__title">계정 설정</span>
              <span className="vr-nav-row__meta">프로필 · 비밀번호 · 로그인된 기기</span>
              <Icon name="chevron_right" />
            </a>
          </div>
        );
    }
  }

  return (
    <AppShell active="settings" title="설정">
      {SETTINGS_SECTIONS.map((section) => (
        <Section key={section.id} title={section.title} card className="vr-settings-section">
          {section.items.map((item) => (
            <div key={item}>{renderSetting(item)}</div>
          ))}
        </Section>
      ))}

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
