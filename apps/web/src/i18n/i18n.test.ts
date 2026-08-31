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

test("extracted feature-component copy renders English by default, Korean when selected", async () => {
  await setUiLanguage("en");
  assert.equal(i18n.t("recorder.stopAria"), "Stop recording");
  assert.equal(i18n.t("visibility.scopeTitle"), "Who can view");
  assert.equal(i18n.t("visibility.scopes.me_only.label"), "Only me");
  assert.equal(i18n.t("shareDialog.title"), "Share links");
  assert.equal(i18n.t("summary.decisions"), "Decisions");
  assert.equal(i18n.t("speaker.addSpeaker"), "Add speaker");
  assert.equal(i18n.t("theme.game"), "Pixel");
  assert.equal(i18n.t("time.justNow"), "just now");

  await setUiLanguage("ko");
  assert.equal(i18n.t("recorder.stopAria"), "녹음 종료");
  assert.equal(i18n.t("visibility.scopeTitle"), "공개 범위");
  assert.equal(i18n.t("visibility.scopes.me_only.label"), "나만");
  assert.equal(i18n.t("shareDialog.title"), "공유 링크");
  assert.equal(i18n.t("summary.decisions"), "결정사항");
  assert.equal(i18n.t("speaker.addSpeaker"), "화자 추가");
  assert.equal(i18n.t("theme.game"), "픽셀");
  assert.equal(i18n.t("time.justNow"), "방금");

  await setUiLanguage("en");
});

test("feature-component plurals and interpolation resolve in both catalogs", async () => {
  await setUiLanguage("en");
  assert.equal(i18n.t("recorder.uploadFailedTitle", { count: 1 }), "1 upload failed");
  assert.equal(i18n.t("recorder.uploadFailedTitle", { count: 3 }), "3 uploads failed");
  assert.equal(i18n.t("shareDialog.usesCount", { count: 2 }), "2 uses");
  assert.equal(i18n.t("time.minutesAgo", { count: 5 }), "5m ago");
  assert.equal(i18n.t("friends.removeAria", { name: "Sam" }), "Remove Sam");

  await setUiLanguage("ko");
  assert.equal(i18n.t("recorder.uploadFailedTitle", { count: 3 }), "3건의 업로드에 실패했습니다");
  assert.equal(i18n.t("time.minutesAgo", { count: 5 }), "5분 전");
  assert.equal(i18n.t("friends.removeAria", { name: "Sam" }), "Sam 빼기");

  await setUiLanguage("en");
});

test("<Trans> markup keys carry the embedded tags in every catalog", () => {
  // The <strong> / <link> / <icon> placeholders must survive so react-i18next's
  // <Trans> can map them onto real elements at render time.
  for (const key of [
    "settings.micNote",
    "language.note",
    "meetingDetail.splitNotice",
    "visibility.transferAllFriends",
    "shareDialog.guestOff",
    "summary.chunkNotice",
    "integrations.mcpNote",
    "khalaSend.bodyNote",
    "meetingInfo.reviewerOnlyNote",
    "locale.note",
  ]) {
    assert.match(i18n.getResource("en", "translation", key), /<strong>.*<\/strong>/s);
    assert.match(i18n.getResource("ko", "translation", key), /<strong>.*<\/strong>/s);
  }
  assert.match(i18n.getResource("en", "translation", "archive.taxonomyHint"), /<link>.*<\/link>/s);
  assert.match(i18n.getResource("en", "translation", "meetingTitle.labelsHint"), /<link>.*<\/link>/s);
  assert.match(i18n.getResource("en", "translation", "settings.installIos"), /<icon><\/icon>/);
});
