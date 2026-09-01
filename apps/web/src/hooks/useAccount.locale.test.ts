import assert from "node:assert/strict";
import { test } from "node:test";
import { register } from "node:module";
import { pathToFileURL } from "node:url";
import { JSDOM } from "jsdom";
import type { FunctionComponent } from "react";
import type { CurrentAccount } from "@core/api";

/**
 * Integration test for the *real* display-language wiring in `useAccount`.
 *
 * `i18n.test.ts` proves `setUiLanguage`/`resolveUiLocale` in isolation, and
 * `locale-switch.test.ts` proves the picker→i18n glue — but through a
 * `makePicker` stand-in that *re-implements* `useAccount`'s side effects. This
 * file closes that gap (risks.md: "언어 전환 배선이 실물 훅으로 검증되지 않음"):
 * it imports the genuine `useAccount` and drives the paths the runtime walks —
 *
 *   • boot: `api.me()` → `setUiLanguage(me.locale)`
 *   • pick: `LocaleField.onChange` === `useAccount.setAccount` → cache the
 *     account, `void setUiLanguage(next.locale)`, re-render every consumer.
 *
 * The hook needs a DOM (its boot runs in `useEffect`, which SSR never flushes),
 * so we mount it with `react-dom/client` + `act` under jsdom. `@/lib/api` is a
 * mock adapter (no network); `@/i18n` is the real shared instance, so the
 * language actually changes and react-i18next actually re-renders. `LocaleField`
 * itself is `.tsx` (JSX the type-stripping runtime can't execute), so `pick`
 * inlines its one glue line `onChange(await api.updateLocale(next))` with
 * `onChange` bound to the real `setAccount` — the very seam risks.md flagged.
 */

// --- React "act" environment backed by jsdom (effects need a real DOM) ---
const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const g = globalThis as unknown as Record<string, unknown>;
g.window = dom.window;
g.document = dom.window.document;
g.localStorage = dom.window.localStorage;
g.IS_REACT_ACT_ENVIRONMENT = true;

// Teach the node runtime the `@/` aliases (see aliasHook.ts) before importing
// any module that uses them.
const base = pathToFileURL(process.cwd() + "/").href;
register(base + "src/hooks/__testsupport/aliasHook.ts", import.meta.url, { data: { base } });

const React = (await import("react")).default;
const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useTranslation } = await import("react-i18next");
const i18n = (await import("../i18n/index.ts")).default;
const { DEFAULT_UI_LOCALE } = await import("../i18n/index.ts");
const apiMock = await import("./__testsupport/apiMock.ts");

const HANGUL = /[가-힣]/;

type UseAccount = () => {
  account: CurrentAccount | null;
  setAccount: (account: CurrentAccount) => void;
};

/**
 * A fresh `useAccount` module per test — its module-level `cached` starts null,
 * so each test observes a clean boot. The cache-busting query re-instantiates
 * only `useAccount`; its `@/i18n` / `@/lib/*` imports resolve to the shared
 * (unqueried) singletons, so i18n state and the api mock stay coherent.
 */
let freshCounter = 0;
async function freshUseAccount(): Promise<UseAccount> {
  const mod = await import(`./useAccount.ts?fresh=${++freshCounter}`);
  return mod.useAccount as UseAccount;
}

/** The whole shell in miniature: every span reads copy through react-i18next. */
function makeShell(useAccount: UseAccount) {
  const ref: { account: CurrentAccount | null; setAccount?: (a: CurrentAccount) => void } = {
    account: null,
  };
  const Shell: FunctionComponent = () => {
    const { account, setAccount } = useAccount();
    const { t } = useTranslation();
    ref.account = account;
    ref.setAccount = setAccount;
    return React.createElement(
      "div",
      null,
      React.createElement("span", { className: "save" }, t("common.save")),
      React.createElement("span", { className: "nav" }, t("nav.meetings")),
      React.createElement("span", { className: "title" }, t("settings.title")),
    );
  };
  return { Shell, ref };
}

async function flush() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

async function mount(Comp: FunctionComponent) {
  const container = dom.window.document.createElement("div");
  dom.window.document.body.appendChild(container);
  const root = createRoot(container);
  await act(async () => {
    root.render(React.createElement(Comp));
  });
  await flush(); // let the boot effect's api.me()/setUiLanguage settle
  const unmount = async () => {
    await act(async () => root.unmount());
    container.remove();
  };
  return { container, unmount };
}

/** Faithful to `LocaleField.pick`: `onChange(await api.updateLocale(next))`. */
async function pick(ref: { setAccount?: (a: CurrentAccount) => void }, next: string) {
  await act(async () => {
    ref.setAccount!(await apiMock.api.updateLocale(next));
  });
  await flush();
}

test("(a) no stored locale → the shell renders English by default", async () => {
  await i18n.changeLanguage(DEFAULT_UI_LOCALE);
  // The app boots in English before the account loads (i18n `lng` default).
  assert.equal(i18n.language, "en");

  // An account with no chosen UI language (backend default may arrive as null).
  apiMock.__cfg.me = async () => apiMock.account({ locale: null as unknown as string });

  const useAccount = await freshUseAccount();
  const { Shell, ref } = makeShell(useAccount);
  const { container, unmount } = await mount(Shell);

  // resolveUiLocale(null) → "en": boot leaves the shell in English, not blank
  // or half-translated.
  assert.equal(i18n.language, "en");
  assert.ok(ref.account, "boot resolved the account");
  assert.equal(container.innerHTML, '<div><span class="save">Save</span><span class="nav">Meetings</span><span class="title">Settings</span></div>');
  assert.doesNotMatch(container.innerHTML, HANGUL);

  await unmount();
});

test("(b) stored locale=en persists across refresh and reconnect", async () => {
  await i18n.changeLanguage("ko"); // ensure the switch to en is observable, not a no-op
  apiMock.__cfg.me = async () => apiMock.account({ locale: "en" });

  // Refresh: a brand-new boot (cache empty) restores the stored en account.
  const useAccount = await freshUseAccount();
  const { Shell, ref } = makeShell(useAccount);
  const first = await mount(Shell);
  assert.equal(i18n.language, "en", "me() returned en → shell is English after boot");
  assert.equal(ref.account?.locale, "en");
  assert.doesNotMatch(first.container.innerHTML, HANGUL);
  await first.unmount();

  // Reconnect: the same session remounts with a warm cache (no second me()).
  // The stored English must survive — never snap back to the ko default.
  let meCalls = 0;
  apiMock.__cfg.me = async () => {
    meCalls++;
    return apiMock.account({ locale: "en" });
  };
  const second = await mount(Shell);
  assert.equal(meCalls, 0, "warm cache: reconnect does not re-fetch");
  assert.equal(i18n.language, "en", "English held across reconnect");
  assert.equal(second.container.innerHTML, '<div><span class="save">Save</span><span class="nav">Meetings</span><span class="title">Settings</span></div>');
  await second.unmount();
});

test("(c) picking a language re-renders the whole shell immediately, no reload", async () => {
  apiMock.__cfg.me = async () => apiMock.account({ locale: "en" });
  const startHref = dom.window.location.href;

  const useAccount = await freshUseAccount();
  const { Shell, ref } = makeShell(useAccount);
  const { container, unmount } = await mount(Shell);
  assert.equal(container.querySelector(".title")?.textContent, "Settings");

  let switches = 0;
  const onSwitch = () => {
    switches++;
  };
  i18n.on("languageChanged", onSwitch);
  try {
    await pick(ref, "ko");

    // The live DOM flipped in place — react-i18next re-rendered every consumer
    // off the single languageChanged signal. No manual re-render, no reload.
    assert.equal(switches, 1);
    assert.equal(i18n.language, "ko");
    assert.equal(container.innerHTML, '<div><span class="save">저장</span><span class="nav">회의</span><span class="title">설정</span></div>');
    // The choice landed in the real hook cache (so the recorder/session follow).
    assert.equal(ref.account?.locale, "ko");
    // Nothing navigated: same document, same URL.
    assert.equal(dom.window.location.href, startHref);
  } finally {
    i18n.off("languageChanged", onSwitch);
  }

  await unmount();
});

test("(d) ko↔en round-trip leaves no stale Korean and no missing-key fallback", async () => {
  apiMock.__cfg.me = async () => apiMock.account({ locale: "en" });
  const useAccount = await freshUseAccount();
  const { Shell, ref } = makeShell(useAccount);
  const { container, unmount } = await mount(Shell);

  const keys = ["common.save", "nav.meetings", "settings.title"];
  const cells = () => ["save", "nav", "title"].map((c) => container.querySelector(`.${c}`)?.textContent ?? "");
  // A key echoed back verbatim means a missing catalog entry (i18next returns
  // the key when the string is absent) — the "missing translation" smell.
  const noRawKeys = () => cells().every((text) => !keys.includes(text));

  await pick(ref, "ko");
  assert.equal(container.innerHTML, '<div><span class="save">저장</span><span class="nav">회의</span><span class="title">설정</span></div>');
  assert.ok(noRawKeys(), "ko: every cell resolved to a real string");

  await pick(ref, "en");
  assert.equal(i18n.language, "en");
  assert.equal(container.innerHTML, '<div><span class="save">Save</span><span class="nav">Meetings</span><span class="title">Settings</span></div>');
  assert.doesNotMatch(container.innerHTML, HANGUL, "en: no stale Korean survives the switch back");
  assert.ok(noRawKeys(), "en: every cell resolved to a real string");

  await pick(ref, "ko");
  assert.doesNotMatch(container.querySelector(".save")?.textContent ?? "", /Save/);
  assert.ok(noRawKeys(), "ko again: still fully translated");

  await unmount();
  await i18n.changeLanguage(DEFAULT_UI_LOCALE);
});
