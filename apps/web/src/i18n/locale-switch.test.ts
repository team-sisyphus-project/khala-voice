import assert from "node:assert/strict";
import { test } from "node:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { useTranslation } from "react-i18next";
import i18n, { DEFAULT_UI_LOCALE, setUiLanguage } from "./index.ts";

/**
 * Integration test for the immediate full-screen language switch (M3).
 *
 * The unit tests in `i18n.test.ts` prove `setUiLanguage`/`resolveUiLocale` in
 * isolation. This file locks the *wiring* the runtime actually walks when a user
 * picks a language in settings:
 *
 *   LocaleField.pick → api.updateLocale → onChange (useAccount.setAccount)
 *     → setUiLanguage → i18n.changeLanguage → react-i18next re-renders every
 *       `useTranslation`/`<Trans>` consumer (the whole shell) — no page reload.
 *
 * `updateLocale` is a mock adapter (no network). Everything from `setUiLanguage`
 * onward is the real code. A `useTranslation` consumer stands in for the shell;
 * rendering it before/after the pick proves the visible copy flips, and the
 * `languageChanged` subscription proves react-i18next receives the re-render
 * signal synchronously with the save — not on the next reload.
 */

/** Any component that reads copy through react-i18next: AppShell, AppSettingsPage, bottom nav, ... */
function Shell() {
  const { t } = useTranslation();
  return createElement(
    "div",
    null,
    createElement("span", { className: "save" }, t("common.save")),
    createElement("span", { className: "nav" }, t("nav.meetings")),
    createElement("span", { className: "title" }, t("settings.title")),
  );
}

const renderShell = () => renderToStaticMarkup(createElement(Shell));

/**
 * Faithful stand-in for the two glue steps between the picker and i18n:
 *
 * - `setAccount` mirrors `useAccount.setAccount` — cache the account, then fire
 *   `setUiLanguage(locale)` so the shell follows the account now, not on reload.
 *   Production discards the promise (`void`); the test keeps a handle purely to
 *   await the switch settling before asserting (a test-timing aid, not a
 *   behavior change — the runtime ordering is identical).
 * - `pick` mirrors `LocaleField.pick` — `onChange(await api.updateLocale(next))`.
 */
function makePicker(updateLocale: (locale: string) => Promise<{ locale: string }>) {
  let account: { locale: string } | null = null;
  let switching: Promise<unknown> = Promise.resolve();

  const setAccount = (next: { locale: string }) => {
    account = next; // useAccount: cached = next (the recorder must not build a session in the old language)
    switching = setUiLanguage(next.locale); // useAccount: void setUiLanguage(next.locale)
  };

  const pick = async (next: string) => {
    setAccount(await updateLocale(next)); // LocaleField.pick: onChange(await api.updateLocale(next))
  };

  return { pick, settled: () => switching, saved: () => account };
}

test("picking a language re-renders the whole shell immediately and persists (M3)", async () => {
  await setUiLanguage(DEFAULT_UI_LOCALE);
  assert.equal(renderShell(), "<div><span class=\"save\">Save</span><span class=\"nav\">Meetings</span><span class=\"title\">Settings</span></div>");

  let reRenders = 0;
  const onChange = () => {
    reRenders++;
  };
  i18n.on("languageChanged", onChange);

  // Mock backend: PATCH /api/me/locale echoes the saved account.
  const picker = makePicker(async (locale) => ({ locale }));

  try {
    await picker.pick("ko");
    await picker.settled();

    // The re-render signal react-i18next binds to fired once — the shell repaints
    // in place, no `window.location.reload`, no waiting for the next navigation.
    assert.equal(reRenders, 1);
    assert.equal(i18n.language, "ko");

    // Every translated surface in the shell is now Korean.
    assert.equal(
      renderShell(),
      "<div><span class=\"save\">저장</span><span class=\"nav\">회의</span><span class=\"title\">설정</span></div>",
    );

    // ...and the choice persisted to the account (so the recorder/session pick it up too).
    assert.deepEqual(picker.saved(), { locale: "ko" });
  } finally {
    i18n.off("languageChanged", onChange);
    await setUiLanguage(DEFAULT_UI_LOCALE);
  }
});

test("boot applies the account's stored locale over the English default", async () => {
  await setUiLanguage(DEFAULT_UI_LOCALE);
  // The app boots in English (i18n `lng: DEFAULT_UI_LOCALE`) before the account loads.
  assert.equal(i18n.language, "en");
  assert.match(renderShell(), /Meetings/);

  // useAccount boot effect: api.me() resolves the stored account, then setUiLanguage(me.locale).
  const me = { locale: "ko" };
  await setUiLanguage(me.locale);

  assert.equal(i18n.language, "ko");
  assert.match(renderShell(), /회의/);

  await setUiLanguage(DEFAULT_UI_LOCALE);
});

test("no user-facing surface renders a stale language on an uncatalogued locale", async () => {
  await setUiLanguage(DEFAULT_UI_LOCALE);

  // A backend-valid locale with no reviewed catalog yet (ja/es/zh_CN/zh_TW).
  // resolveUiLocale collapses it to English, so the shell renders fully in the
  // fallback language — never a half-translated or previously-selected mix.
  const picker = makePicker(async (locale) => ({ locale }));
  await picker.pick("ja");
  await picker.settled();

  assert.equal(i18n.language, "en");
  assert.equal(
    renderShell(),
    "<div><span class=\"save\">Save</span><span class=\"nav\">Meetings</span><span class=\"title\">Settings</span></div>",
  );
  assert.deepEqual(picker.saved(), { locale: "ja" });

  await setUiLanguage(DEFAULT_UI_LOCALE);
});
