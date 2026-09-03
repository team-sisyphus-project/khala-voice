import { equal, notDeepEqual, ok } from "node:assert/strict";
import { describe, it } from "node:test";
import {
  classifyMediaError,
  detectPlatform,
  isPermissionCode,
  micErrorTitle,
  micRecoveryGuide,
  refinePermissionCode,
} from "./permission.ts";

/** Mimics DOMException — node has no getUserMedia. */
function domError(name: string, message = ""): Error {
  const error = new Error(message);
  error.name = name;
  return error;
}

const UA = {
  chromeMac:
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
  chromeWin:
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
  chromeAndroid:
    "Mozilla/5.0 (Linux; Android 14; SM-S918N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
  safariMac:
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
  safariIphone:
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
  chromeIphone:
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/131.0.0.0 Mobile/15E148 Safari/604.1",
  ipadOs:
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
  edge: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0",
  samsung:
    "Mozilla/5.0 (Linux; Android 14; SM-S918N) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/23.0 Chrome/115.0.0.0 Mobile Safari/537.36",
  firefox: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0",
  kakaoAndroid:
    "Mozilla/5.0 (Linux; Android 14; SM-S918N) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/115.0.0.0 Mobile Safari/537.36 KAKAOTALK 10.4.0",
  kakaoIos:
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 KAKAOTALK 10.4.0",
  androidWebView:
    "Mozilla/5.0 (Linux; Android 14; SM-S918N; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/115.0.0.0 Mobile Safari/537.36",
};

describe("detectPlatform", () => {
  it("desktop Chrome", () => {
    const p = detectPlatform(UA.chromeMac, { maxTouchPoints: 0, standalone: false });
    equal(p.browser, "chrome");
    equal(p.engine, "blink");
    equal(p.os, "macos");
    equal(p.mobile, false);
    equal(p.webview, false);
  });

  it("Edge is Edge even with Chrome in the UA", () => {
    // Getting the order wrong would guide Edge users down Chrome menu paths
    equal(detectPlatform(UA.edge, { maxTouchPoints: 0, standalone: false }).browser, "edge");
  });

  it("Samsung Internet does not leak into Chrome either", () => {
    const p = detectPlatform(UA.samsung, { maxTouchPoints: 1, standalone: false });
    equal(p.browser, "samsung");
    equal(p.engine, "blink");
    equal(p.os, "android");
  });

  it("Firefox is gecko", () => {
    const p = detectPlatform(UA.firefox, { maxTouchPoints: 0, standalone: false });
    equal(p.browser, "firefox");
    equal(p.engine, "gecko");
  });

  it("iOS Safari", () => {
    const p = detectPlatform(UA.safariIphone, { maxTouchPoints: 5, standalone: false });
    equal(p.os, "ios");
    equal(p.engine, "webkit");
    equal(p.mobile, true);
  });

  it("Chrome on iOS still has a WebKit engine", () => {
    // Permission guidance must follow the engine, not the browser name.
    // Giving CriOS the Chrome desktop guidance sends users hunting for menus that do not exist.
    const p = detectPlatform(UA.chromeIphone, { maxTouchPoints: 5, standalone: false });
    equal(p.browser, "chrome");
    equal(p.engine, "webkit");
    equal(p.os, "ios");
  });

  it("iPadOS pretends to be a Mac — split by touch points", () => {
    equal(detectPlatform(UA.ipadOs, { maxTouchPoints: 5, standalone: false }).os, "ios");
    equal(detectPlatform(UA.ipadOs, { maxTouchPoints: 0, standalone: false }).os, "macos");
  });

  it("catches the KakaoTalk in-app browser", () => {
    ok(detectPlatform(UA.kakaoAndroid, { maxTouchPoints: 5, standalone: false }).webview);
    ok(detectPlatform(UA.kakaoIos, { maxTouchPoints: 5, standalone: false }).webview);
  });

  it("catches Android WebView (; wv)", () => {
    ok(detectPlatform(UA.androidWebView, { maxTouchPoints: 5, standalone: false }).webview);
  });

  it("a home-screen PWA is not an in-app browser", () => {
    // iOS standalone drops the Safari token from the UA. Mistaking that for
    // in-app would show "open in another browser" to properly installed users.
    const ua = UA.safariIphone.replace(" Safari/604.1", "");
    equal(detectPlatform(ua, { maxTouchPoints: 5, standalone: true }).webview, false);
  });
});

describe("classifyMediaError", () => {
  it("Chrome splits only by message", () => {
    equal(classifyMediaError(domError("NotAllowedError", "Permission denied")), "permission_denied");
    equal(
      classifyMediaError(domError("NotAllowedError", "Permission dismissed")),
      "permission_dismissed",
    );
    equal(
      classifyMediaError(domError("NotAllowedError", "Permission denied by system")),
      "system_denied",
    );
    equal(
      classifyMediaError(
        domError("NotAllowedError", "Access to the feature is disallowed by permissions policy"),
      ),
      "embed_blocked",
    );
  });

  it("an empty message, as in Safari, still reads as a permission error", () => {
    equal(classifyMediaError(domError("NotAllowedError")), "permission_denied");
  });

  it("accepts legacy names too", () => {
    equal(classifyMediaError(domError("PermissionDeniedError")), "permission_denied");
    equal(classifyMediaError(domError("DevicesNotFoundError")), "no_device");
    equal(classifyMediaError(domError("TrackStartError")), "device_busy");
  });

  it("distinguishes busy, missing, and constrained", () => {
    equal(classifyMediaError(domError("NotReadableError")), "device_busy");
    equal(classifyMediaError(domError("NotFoundError")), "no_device");
    equal(classifyMediaError(domError("OverconstrainedError")), "device_unavailable");
  });

  it("unrecognized and empty values are unknown", () => {
    equal(classifyMediaError(domError("WeirdError")), "unknown");
    equal(classifyMediaError(null), "unknown");
    equal(classifyMediaError(undefined), "unknown");
    equal(classifyMediaError("a string"), "unknown");
  });
});

describe("refinePermissionCode", () => {
  it("denied upgrades to a hardened block", () => {
    equal(refinePermissionCode("permission_denied", "denied"), "permission_blocked");
    equal(refinePermissionCode("permission_dismissed", "denied"), "permission_blocked");
  });

  it("prompt means asking is still possible", () => {
    equal(refinePermissionCode("permission_denied", "prompt"), "permission_dismissed");
  });

  it("never presumes on Safari (unknown)", () => {
    // Presuming blocked here walls off users who could actually be asked again
    equal(refinePermissionCode("permission_denied", "unknown"), "permission_denied");
  });

  it("OS/iframe blocks are not overwritten by the site permission state", () => {
    equal(refinePermissionCode("system_denied", "prompt"), "system_denied");
    equal(refinePermissionCode("embed_blocked", "denied"), "embed_blocked");
  });

  it("codes unrelated to permission pass through", () => {
    equal(refinePermissionCode("device_busy", "denied"), "device_busy");
    equal(refinePermissionCode("no_device", "prompt"), "no_device");
  });
});

describe("micRecoveryGuide", () => {
  const chrome = detectPlatform(UA.chromeWin, { maxTouchPoints: 0, standalone: false });
  const ios = detectPlatform(UA.safariIphone, { maxTouchPoints: 5, standalone: false });
  const kakao = detectPlatform(UA.kakaoIos, { maxTouchPoints: 5, standalone: false });

  // Guidance now comes out as locale-free keys (GuideMessage) — assert keys, not wording.
  const stepKeys = (guide: { steps: { key: string }[] }) => guide.steps.map((s) => s.key);

  it("a hardened block does not suggest retrying", () => {
    const guide = micRecoveryGuide("permission_blocked", chrome);
    equal(guide.retryable, false);
    equal(guide.needsSettings, true);
    ok(guide.steps.length > 0);
  });

  it("a dismissed prompt retries fine", () => {
    const guide = micRecoveryGuide("permission_dismissed", chrome);
    equal(guide.retryable, true);
    equal(guide.needsSettings, false);
  });

  it("guidance paths differ per device", () => {
    const win = stepKeys(micRecoveryGuide("permission_blocked", chrome));
    const iphone = stepKeys(micRecoveryGuide("permission_blocked", ios));

    ok(win.includes("step.siteChromiumIcon"));
    ok(iphone.includes("step.siteIosAa"));
    notDeepEqual(iphone, win);
  });

  it("Chromium guidance carries the browser menu name as a param", () => {
    // The shell translates the wording, but the "Edge/Chrome" split is core logic, so it rides as a param.
    const edge = detectPlatform(UA.edge, { maxTouchPoints: 0, standalone: false });
    const allow = micRecoveryGuide("permission_blocked", edge).steps.find(
      (s) => s.key === "step.siteChromiumAllow",
    );
    ok(allow);
    equal(allow?.params?.menu, "Edge");
  });

  it("in-app browsers have one conclusion for permission errors — open in another browser", () => {
    const guide = micRecoveryGuide("permission_blocked", kakao);
    equal(guide.retryable, false);
    equal(guide.needsSettings, false);
    ok(stepKeys(guide).includes("step.openInBrowserIosSafari"));
  });

  it("OS blocks send users to system settings, not browser settings", () => {
    const guide = micRecoveryGuide("system_denied", chrome);
    ok(stepKeys(guide).some((k) => k.startsWith("step.system")));
    equal(guide.retryable, false);
  });

  it("every code has a cause and guidance", () => {
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
      const guide = micRecoveryGuide(code, chrome);
      ok(guide.cause.key.length > 0, `${code} has no cause`);
      ok(guide.steps.length > 0, `${code} has no guidance`);
      ok(guide.steps.every((s) => s.key.length > 0), `${code} has an empty step`);
      ok(micErrorTitle(code).key.length > 0, `${code} has no title`);
    }
  });
});

describe("isPermissionCode", () => {
  it("true only for the permission family", () => {
    ok(isPermissionCode("permission_blocked"));
    ok(isPermissionCode("system_denied"));
    equal(isPermissionCode("device_busy"), false);
    equal(isPermissionCode("interrupted"), false);
  });
});
