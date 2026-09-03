import { useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { api } from "@/lib/api";
import { DEFAULT_UI_LOCALE, SUPPORTED_UI_LOCALES } from "@/i18n";
import type { CurrentAccount } from "@core/api";

/**
 * Picks the app's display (UI) language.
 *
 * ## A separate component from the transcription language (`LanguageField`)
 *
 * Using the app in Korean while recording meetings in English is common. So
 * the account holds the two values **separately** (`locale` ≠
 * `transcribe_language`), and they're picked in separate places. Merged into
 * one component, changing one would end up touching the other.
 *
 * ## Why no auto-detection
 *
 * A misguessed transcription language throws away an entire meeting's
 * transcript (while spending credits), but a misguessed UI language is one
 * click away from being fixed in this dropdown. So the default is fixed
 * English (`DEFAULT_UI_LOCALE`) with no browser detection.
 *
 * ## The offered list
 *
 * The backend allows 6 locales, but only languages with a reviewed catalog
 * (`SUPPORTED_UI_LOCALES`) are offered. Letting someone pick a catalog-less
 * language makes the screen fall back to English, so the chosen value and the
 * visible language would disagree.
 */

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

  // Before the account arrives, show the default (English) — the language the app booted in.
  const value = account?.locale ?? DEFAULT_UI_LOCALE;

  async function pick(next: string) {
    setSaving(true);
    setError(null);

    try {
      // onChange(setAccount) refreshes the cache and switches the i18next
      // language immediately — the screen redraws now, not on the next reload.
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
          // Each option renders in its own language (endonym) via `lng`, so a
          // speaker recognizes it regardless of the active UI language.
          <option key={locale} value={locale}>
            {t(`locale.names.${locale}`, { lng: locale })}
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
