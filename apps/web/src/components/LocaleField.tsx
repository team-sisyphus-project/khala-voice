import { useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { api } from "@/lib/api";
import { DEFAULT_UI_LOCALE, SUPPORTED_UI_LOCALES } from "@/i18n";
import type { UiLocale } from "@/i18n";
import type { CurrentAccount } from "@core/api";

/**
 * 앱 화면(UI) 표시 언어를 고른다.
 *
 * ## 전사 언어(`LanguageField`)와 별도 컴포넌트다
 *
 * 한국어로 앱을 쓰면서 영어 회의를 녹음하는 일이 흔하다. 그래서 계정에도 두 값이
 * **따로** 있고(`locale` ≠ `transcribe_language`), 고르는 자리도 따로다. 둘을 한
 * 컴포넌트로 묶으면 한쪽을 바꿀 때 다른 쪽까지 건드리게 된다.
 *
 * ## 왜 자동 감지가 없나
 *
 * 전사 언어는 오추측하면 그 회의 전사가 통째로 버려지지만(크레딧은 나간다), UI
 * 언어 오추측은 이 드롭다운에서 1클릭으로 되돌릴 수 있다. 그래서 기본은 고정 영어
 * (`DEFAULT_UI_LOCALE`)이고 브라우저 감지는 두지 않는다.
 *
 * ## 제시 목록
 *
 * 백엔드는 6개 locale 을 허용하지만, 리뷰된 카탈로그가 있는 언어(`SUPPORTED_UI_LOCALES`)
 * 만 제시한다. 카탈로그 없는 언어를 고르게 하면 화면은 영어로 폴백되어 고른 값과
 * 보이는 언어가 어긋난다.
 */

/** 언어별 표시 이름 — 각 언어의 원어명으로 적는다(고르는 사람이 자기 언어를 알아본다). */
const UI_LOCALE_LABELS: Record<UiLocale, string> = {
  en: "English",
  ko: "한국어",
};

export function LocaleField({
  account,
  onChange,
}: {
  account: CurrentAccount | null;
  onChange: (account: CurrentAccount) => void;
}) {
  const { t } = useTranslation();
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // 계정을 아직 못 받았으면 기본(영어)으로 보여준다 — 앱이 부팅한 언어와 같다.
  const value = account?.locale ?? DEFAULT_UI_LOCALE;

  async function pick(next: string) {
    setSaving(true);
    setError(null);

    try {
      // onChange(setAccount) 가 캐시를 갱신하고 i18next 언어를 즉시 바꾼다 —
      // 화면이 다음 새로고침이 아니라 지금 다시 그려진다.
      onChange(await api.updateLocale(next));
    } catch (e) {
      setError(e instanceof Error ? e.message : t("locale.saveError"));
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="vr-filter__group">
      <span className="vr-filter__label">{t("locale.label")}</span>

      <select
        className="mobile-field__input"
        value={value}
        disabled={saving || account === null}
        onChange={(e) => void pick(e.target.value)}
        aria-label={t("locale.label")}
      >
        {SUPPORTED_UI_LOCALES.map((locale) => (
          <option key={locale} value={locale}>
            {UI_LOCALE_LABELS[locale]}
          </option>
        ))}
      </select>

      <p className="vr-note vr-note--small">
        <Trans t={t} i18nKey="locale.note" components={{ strong: <strong /> }} />
      </p>

      {error && (
        <p className="vr-note vr-note--small" role="alert" style={{ color: "var(--mobile-danger)" }}>
          {error}
        </p>
      )}
    </div>
  );
}
