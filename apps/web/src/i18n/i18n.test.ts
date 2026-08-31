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

test("extracted shell/navigation copy renders English by default, Korean when selected", async () => {
  await setUiLanguage("en");
  assert.equal(i18n.t("nav.meetings"), "Meetings");
  assert.equal(i18n.t("settings.title"), "Settings");
  assert.equal(i18n.t("archive.title"), "Archive");

  await setUiLanguage("ko");
  assert.equal(i18n.t("nav.meetings"), "회의");
  assert.equal(i18n.t("settings.title"), "설정");
  assert.equal(i18n.t("archive.title"), "아카이브");

  await setUiLanguage("en");
});

test("interpolation and plurals resolve in both catalogs", async () => {
  await setUiLanguage("en");
  assert.equal(i18n.t("archive.loadMore", { shown: 30, total: 90 }), "Show more (30/90)");
  assert.equal(i18n.t("archive.results", { count: 1 }), "1 result");
  assert.equal(i18n.t("archive.results", { count: 5 }), "5 results");
  assert.equal(i18n.t("taxonomy.meetings", { count: 3 }), "3 meetings");

  await setUiLanguage("ko");
  assert.equal(i18n.t("archive.loadMore", { shown: 30, total: 90 }), "더 보기 (30/90)");
  assert.equal(i18n.t("archive.results", { count: 5 }), "5개");
  assert.equal(i18n.t("taxonomy.meetings", { count: 3 }), "회의 3개");

  await setUiLanguage("en");
});

test("<Trans> markup keys carry the embedded tags in every catalog", () => {
  // The <strong> / <link> / <icon> placeholders must survive so react-i18next's
  // <Trans> can map them onto real elements at render time.
  for (const key of ["settings.micNote", "language.note", "meetingDetail.splitNotice"]) {
    assert.match(i18n.getResource("en", "translation", key), /<strong>.*<\/strong>/s);
    assert.match(i18n.getResource("ko", "translation", key), /<strong>.*<\/strong>/s);
  }
  assert.match(i18n.getResource("en", "translation", "archive.taxonomyHint"), /<link>.*<\/link>/s);
  assert.match(i18n.getResource("en", "translation", "settings.installIos"), /<icon><\/icon>/);
});
