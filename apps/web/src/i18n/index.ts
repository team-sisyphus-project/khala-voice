import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import { en } from "./locales/en.ts";
import { ko } from "./locales/ko.ts";

/**
 * App display-language (i18n) setup for the web shell.
 *
 * **UI language ≠ transcription language.** `locale` (this) drives what the app
 * chrome reads; `transcribe_language` drives STT and is handled separately
 * (`lib/prefs.ts`, `LanguageField`). Do not merge the two — a person often runs
 * the app in one language while recording meetings in another.
 *
 * Default display language is **English** — this is an open-source product
 * published internationally. New accounts default to `en`; existing accounts
 * keep whatever `locale` they stored. When an account's `locale` has no
 * reviewed catalog yet (ja/es/zh_CN/zh_TW), i18next falls back to English.
 */

/** Locales that ship a reviewed catalog. The UI language picker offers only these. */
export const SUPPORTED_UI_LOCALES = ["en", "ko"] as const;
export type UiLocale = (typeof SUPPORTED_UI_LOCALES)[number];

/** New-signup / no-account default. Fixed English (browser detection deferred). */
export const DEFAULT_UI_LOCALE: UiLocale = "en";

export const resources = {
  en: { translation: en },
  ko: { translation: ko },
} as const;

export function isSupportedUiLocale(value: unknown): value is UiLocale {
  return typeof value === "string" && (SUPPORTED_UI_LOCALES as readonly string[]).includes(value);
}

/**
 * Map an account `locale` to the language i18next should run in.
 *
 * A reviewed catalog → that catalog. Anything else (null, unset, or one of the
 * not-yet-authored locales) → English. Keeps the active language honest with
 * what is actually rendered.
 */
export function resolveUiLocale(locale: string | null | undefined): UiLocale {
  return isSupportedUiLocale(locale) ? locale : DEFAULT_UI_LOCALE;
}

// Initialize the shared instance once, synchronously (bundled resources — no
// network load). Safe to import for its side effect from the app entry point.
void i18n.use(initReactI18next).init({
  resources,
  lng: DEFAULT_UI_LOCALE,
  fallbackLng: DEFAULT_UI_LOCALE,
  supportedLngs: [...SUPPORTED_UI_LOCALES],
  interpolation: {
    // React already escapes rendered values; double-escaping mangles copy.
    escapeValue: false,
  },
  returnNull: false,
});

/**
 * Switch the app's display language at runtime.
 *
 * Accepts a raw account `locale`; unsupported values resolve to English. react
 * components using `useTranslation`/`Trans` re-render on the change. Returns the
 * `changeLanguage` promise so callers can await catalog readiness if needed.
 */
export function setUiLanguage(locale: string | null | undefined): Promise<unknown> {
  const next = resolveUiLocale(locale);
  if (i18n.language === next) return Promise.resolve();
  return i18n.changeLanguage(next);
}

export default i18n;
