import assert from "node:assert/strict";
import { test } from "node:test";
import i18n, {
  DEFAULT_UI_LOCALE,
  resolveUiLocale,
  setUiLanguage,
  SUPPORTED_UI_LOCALES,
} from "./index.ts";

test("boots initialized with English as the default language", () => {
  assert.equal(i18n.isInitialized, true);
  assert.equal(DEFAULT_UI_LOCALE, "en");
  assert.equal(i18n.language, "en");
  assert.equal(i18n.t("common.save"), "Save");
});

test("resolveUiLocale maps to a reviewed catalog or falls back to English", () => {
  assert.equal(resolveUiLocale("ko"), "ko");
  assert.equal(resolveUiLocale("en"), "en");
  // Backend-valid locales with no catalog yet fall back to English.
  assert.equal(resolveUiLocale("ja"), "en");
  assert.equal(resolveUiLocale("zh_CN"), "en");
  // Unset / unknown → English (fixed-English default, no browser detection).
  assert.equal(resolveUiLocale(null), "en");
  assert.equal(resolveUiLocale(undefined), "en");
  assert.equal(resolveUiLocale("xx"), "en");
});

test("only ko/en ship reviewed catalogs", () => {
  assert.deepEqual([...SUPPORTED_UI_LOCALES], ["en", "ko"]);
});

test("changing language switches the rendered copy (drives a re-render)", async () => {
  await setUiLanguage("ko");
  assert.equal(i18n.language, "ko");
  assert.equal(i18n.t("common.save"), "저장");

  await setUiLanguage("en");
  assert.equal(i18n.language, "en");
  assert.equal(i18n.t("common.save"), "Save");
});

test("unsupported locale renders via the English fallback", async () => {
  await setUiLanguage("ja");
  // resolveUiLocale collapses ja → en, so the active language is English.
  assert.equal(i18n.language, "en");
  assert.equal(i18n.t("common.cancel"), "Cancel");
  await setUiLanguage("en");
});
