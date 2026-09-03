import assert from "node:assert/strict";
import { test } from "vitest";
// Import the source module directly (with extension): the package's index.ts
// uses bundler-resolved extensionless re-exports that node's ESM loader can't
// follow. permission.ts is self-contained and holds all three of these.
import {
  detectPlatform,
  micErrorTitle,
  micRecoveryGuide,
} from "../../../../packages/core/src/recorder/permission.ts";
import i18n, { setUiLanguage } from "../i18n/index.ts";
import { errorTitle, guideText } from "./recorderGuide.ts";

/**
 * These lock the grain's core promise: `@core/recorder` emits locale-free keys,
 * and the shell renders them in the active UI language — so UI=en leaves no
 * Korean on the recording screen, and UI=ko still renders Korean.
 */

const HANGUL = /[가-힣]/;
const CHROME_WIN =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const chrome = detectPlatform(CHROME_WIN, { maxTouchPoints: 0, standalone: false });

test("mic guidance renders English with no Korean when UI=en", async () => {
  await setUiLanguage("en");
  const t = i18n.t;

  const guide = micRecoveryGuide("permission_blocked", chrome);
  const rendered = [
    errorTitle(t, "permission_blocked"),
    guideText(t, guide.cause),
    ...guide.steps.map((step) => guideText(t, step)),
  ];

  for (const line of rendered) {
    assert.equal(HANGUL.test(line), false, `unexpected Korean: ${line}`);
    assert.ok(line.length > 0);
  }

  assert.equal(errorTitle(t, "permission_blocked"), "The microphone is blocked");
  assert.ok(guideText(t, guide.cause).startsWith("The microphone is blocked"));

  await setUiLanguage("en");
});

test("the same core keys render Korean when UI=ko", async () => {
  await setUiLanguage("ko");
  const t = i18n.t;

  const guide = micRecoveryGuide("permission_blocked", chrome);
  assert.equal(errorTitle(t, "permission_blocked"), "마이크가 차단되어 있습니다");
  assert.ok(HANGUL.test(guideText(t, guide.cause)));
  assert.ok(guide.steps.every((step) => guideText(t, step).length > 0));

  await setUiLanguage("en");
});

test("core-supplied interpolation params flow through translation", async () => {
  await setUiLanguage("en");
  const t = i18n.t;

  const edge = detectPlatform(`${CHROME_WIN} Edg/131.0.0.0`, {
    maxTouchPoints: 0,
    standalone: false,
  });
  const allow = micRecoveryGuide("permission_blocked", edge).steps.find(
    (step) => step.key === "step.siteChromiumAllow",
  );
  assert.ok(allow);
  // core decides Edge vs Chrome; the shell only interpolates the value it was handed.
  assert.match(guideText(t, allow), /Edge Settings/);

  await setUiLanguage("en");
});

test("mic-error titles resolve for every error code", async () => {
  await setUiLanguage("en");
  const t = i18n.t;

  const codes = [
    "unsupported",
    "insecure_context",
    "permission_denied",
    "permission_blocked",
    "permission_dismissed",
    "system_denied",
    "embed_blocked",
    "no_device",
    "device_unavailable",
    "device_busy",
    "interrupted",
    "unknown",
  ] as const;

  for (const code of codes) {
    const title = errorTitle(t, code);
    // A raw, unresolved key would still contain the "recorder.guide" prefix.
    assert.ok(title.length > 0 && !title.includes("recorder.guide"), `title missing for ${code}`);
    assert.equal(micErrorTitle(code).key, `title.${code}`);
  }
});
