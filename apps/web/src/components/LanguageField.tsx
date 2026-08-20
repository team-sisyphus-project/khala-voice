import { useState } from "react";
import { api } from "@/lib/api";
import { autoLanguage, languageLabel, LANGUAGES } from "@/lib/prefs";
import type { CurrentAccount } from "@core/api";

/**
 * 기본 전사 언어를 고른다.
 *
 * ## 대화(UI) 언어와 다른 값이다
 *
 * 한국어로 앱을 쓰면서 영어 회의를 녹음하는 일이 흔하다. 둘을 묶으면 그때마다
 * UI 언어까지 바꿔야 한다. 그래서 계정에 **따로** 둔다
 * (`transcribe_language` ≠ `locale`).
 *
 * ## 자동이 따로 있다
 *
 * 처음 쓰는 사람에게 고정값을 물리면 다른 언어권 사용자는 매 녹음마다 손으로
 * 바꿔야 하고, 한 번 잊으면 그 회의 전사는 통째로 버려진다(크레딧은 나간다).
 * 그래서 기본은 **자동**(브라우저 언어)이되, 고른 값은 그대로 남는다 —
 * "우리가 정해준 것"과 "내가 고른 것"이 구분돼야 나중에 자동으로 되돌릴 수 있다.
 */
export function LanguageField({
  account,
  onChange,
}: {
  account: CurrentAccount | null;
  onChange: (account: CurrentAccount) => void;
}) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // 계정을 아직 못 받았으면 자동으로 보여준다 — 값이 없다고 빈칸을 두면
  // "언어가 정해지지 않았다"로 읽힌다.
  const value = account?.transcribe_language ?? "";

  async function pick(next: string) {
    setSaving(true);
    setError(null);

    try {
      onChange(await api.updateTranscribeLanguage(next === "" ? null : next));
    } catch (e) {
      setError(e instanceof Error ? e.message : "언어를 저장하지 못했습니다");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="vr-filter__group">
      <span className="vr-filter__label">전사 언어</span>

      <select
        className="mobile-field__input"
        value={value}
        disabled={saving || account === null}
        onChange={(e) => void pick(e.target.value)}
        aria-label="전사 언어"
      >
        <option value="">자동 — {languageLabel(autoLanguage())}</option>
        {LANGUAGES.map((item) => (
          <option key={item.id} value={item.id}>
            {item.label}
          </option>
        ))}
      </select>

      <p className="vr-note vr-note--small">
        회의를 <strong>어떤 언어로 전사할지</strong>입니다. 앱 화면의 언어와는 별개이고,
        모든 기기에 함께 적용됩니다.
      </p>

      {error && (
        <p className="vr-note vr-note--small" role="alert" style={{ color: "var(--mobile-danger)" }}>
          {error}
        </p>
      )}
    </div>
  );
}
