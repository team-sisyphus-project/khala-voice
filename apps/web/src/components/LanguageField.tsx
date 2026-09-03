import { useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { api } from "@/lib/api";
import { autoLanguage, LANGUAGES } from "@/lib/prefs";
import type { CurrentAccount } from "@core/api";

/**
 * Picks the default transcription language.
 *
 * ## A different value from the UI language
 *
 * Using the app in Korean while recording meetings in English is common. Tied
 * together, every such change would drag the UI language along. So the account
 * keeps them **separate** (`transcribe_language` ≠ `locale`).
 *
 * ## Auto is its own option
 *
 * Pinning a fixed value on first-time users means people in other locales must
 * switch by hand for every recording, and one forgotten switch throws away the
 * entire meeting's transcript (while spending credits). So the default is
 * **auto** (browser language), while an explicit pick stays put — "what we
 * decided for you" and "what I chose" must stay distinguishable so auto can be
 * restored later.
 */
export function LanguageField({
  account,
  onChange,
}: {
  account: CurrentAccount | null;
  onChange: (account: CurrentAccount) => void;
}) {
  const { t } = useTranslation();
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Before the account arrives, show auto — leaving it blank for a missing
  // value reads as "no language has been decided".
  const value = account?.transcribe_language ?? "";

  async function pick(next: string) {
    setSaving(true);
    setError(null);

    try {
      onChange(await api.updateTranscribeLanguage(next === "" ? null : next));
    } catch (e) {
      setError(e instanceof Error ? e.message : t("language.saveError"));
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="vr-filter__group">
      <span className="vr-filter__label">{t("language.label")}</span>

      <select
        className="mobile-field__input"
        value={value}
        disabled={saving || account === null}
        onChange={(e) => void pick(e.target.value)}
        aria-label={t("language.label")}
      >
        <option value="">
          {t("language.auto", { label: t(`language.names.${autoLanguage()}`) })}
        </option>
        {LANGUAGES.map((item) => (
          <option key={item.id} value={item.id}>
            {t(`language.names.${item.id}`)}
          </option>
        ))}
      </select>

      <p className="vr-note vr-note--small">
        <Trans t={t} i18nKey="language.note" components={{ strong: <strong /> }} />
      </p>

      {error && (
        <p className="vr-note vr-note--small" role="alert" style={{ color: "var(--mobile-danger)" }}>
          {error}
        </p>
      )}
    </div>
  );
}
