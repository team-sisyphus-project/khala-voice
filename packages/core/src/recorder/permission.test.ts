import { equal, ok } from "node:assert/strict";
import { describe, it } from "node:test";
import {
  classifyMediaError,
  detectPlatform,
  isPermissionCode,
  micErrorTitle,
  micRecoveryGuide,
  refinePermissionCode,
} from "./permission.ts";

/** DOMException 을 흉내낸다 — node 에는 getUserMedia 가 없다. */
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
  it("데스크톱 Chrome", () => {
    const p = detectPlatform(UA.chromeMac, { maxTouchPoints: 0, standalone: false });
    equal(p.browser, "chrome");
    equal(p.engine, "blink");
    equal(p.os, "macos");
    equal(p.mobile, false);
    equal(p.webview, false);
  });

  it("Edge 는 UA 에 Chrome 을 달고 있어도 Edge 다", () => {
    // 순서를 잘못 잡으면 Edge 사용자에게 Chrome 메뉴 경로를 안내하게 된다
    equal(detectPlatform(UA.edge, { maxTouchPoints: 0, standalone: false }).browser, "edge");
  });

  it("삼성 인터넷도 Chrome 으로 새지 않는다", () => {
    const p = detectPlatform(UA.samsung, { maxTouchPoints: 1, standalone: false });
    equal(p.browser, "samsung");
    equal(p.engine, "blink");
    equal(p.os, "android");
  });

  it("Firefox 는 gecko", () => {
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

  it("iOS 의 Chrome 도 엔진은 WebKit 이다", () => {
    // 권한 안내는 브라우저 이름이 아니라 엔진을 따라가야 한다.
    // CriOS 에 Chrome 데스크톱 안내를 주면 존재하지 않는 메뉴를 찾게 된다.
    const p = detectPlatform(UA.chromeIphone, { maxTouchPoints: 5, standalone: false });
    equal(p.browser, "chrome");
    equal(p.engine, "webkit");
    equal(p.os, "ios");
  });

  it("iPadOS 는 맥인 척한다 — 터치 포인트로 가른다", () => {
    equal(detectPlatform(UA.ipadOs, { maxTouchPoints: 5, standalone: false }).os, "ios");
    equal(detectPlatform(UA.ipadOs, { maxTouchPoints: 0, standalone: false }).os, "macos");
  });

  it("카카오톡 인앱 브라우저를 잡는다", () => {
    ok(detectPlatform(UA.kakaoAndroid, { maxTouchPoints: 5, standalone: false }).webview);
    ok(detectPlatform(UA.kakaoIos, { maxTouchPoints: 5, standalone: false }).webview);
  });

  it("안드로이드 WebView(; wv) 를 잡는다", () => {
    ok(detectPlatform(UA.androidWebView, { maxTouchPoints: 5, standalone: false }).webview);
  });

  it("홈 화면 PWA 는 인앱 브라우저가 아니다", () => {
    // iOS standalone 은 UA 에서 Safari 토큰이 빠진다. 이걸 인앱으로 오인하면
    // 정상 설치 사용자에게 "다른 브라우저로 여세요" 를 띄우게 된다.
    const ua = UA.safariIphone.replace(" Safari/604.1", "");
    equal(detectPlatform(ua, { maxTouchPoints: 5, standalone: true }).webview, false);
  });
});

describe("classifyMediaError", () => {
  it("Chrome 은 메시지로만 갈린다", () => {
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

  it("Safari 처럼 메시지가 비어도 권한 오류로는 읽는다", () => {
    equal(classifyMediaError(domError("NotAllowedError")), "permission_denied");
  });

  it("구형 이름도 받는다", () => {
    equal(classifyMediaError(domError("PermissionDeniedError")), "permission_denied");
    equal(classifyMediaError(domError("DevicesNotFoundError")), "no_device");
    equal(classifyMediaError(domError("TrackStartError")), "device_busy");
  });

  it("점유·부재·제약을 구분한다", () => {
    equal(classifyMediaError(domError("NotReadableError")), "device_busy");
    equal(classifyMediaError(domError("NotFoundError")), "no_device");
    equal(classifyMediaError(domError("OverconstrainedError")), "device_unavailable");
  });

  it("모르는 것과 빈 값은 unknown", () => {
    equal(classifyMediaError(domError("WeirdError")), "unknown");
    equal(classifyMediaError(null), "unknown");
    equal(classifyMediaError(undefined), "unknown");
    equal(classifyMediaError("문자열"), "unknown");
  });
});

describe("refinePermissionCode", () => {
  it("denied 면 굳은 차단으로 올린다", () => {
    equal(refinePermissionCode("permission_denied", "denied"), "permission_blocked");
    equal(refinePermissionCode("permission_dismissed", "denied"), "permission_blocked");
  });

  it("prompt 면 아직 물어볼 수 있다", () => {
    equal(refinePermissionCode("permission_denied", "prompt"), "permission_dismissed");
  });

  it("Safari(unknown) 에서는 단정하지 않는다", () => {
    // 여기서 blocked 로 단정하면 실제로는 다시 물어볼 수 있는 사용자의 길을 막는다
    equal(refinePermissionCode("permission_denied", "unknown"), "permission_denied");
  });

  it("OS·iframe 차단은 사이트 권한 상태로 덮지 않는다", () => {
    equal(refinePermissionCode("system_denied", "prompt"), "system_denied");
    equal(refinePermissionCode("embed_blocked", "denied"), "embed_blocked");
  });

  it("권한과 무관한 코드는 그대로", () => {
    equal(refinePermissionCode("device_busy", "denied"), "device_busy");
    equal(refinePermissionCode("no_device", "prompt"), "no_device");
  });
});

describe("micRecoveryGuide", () => {
  const chrome = detectPlatform(UA.chromeWin, { maxTouchPoints: 0, standalone: false });
  const ios = detectPlatform(UA.safariIphone, { maxTouchPoints: 5, standalone: false });
  const kakao = detectPlatform(UA.kakaoIos, { maxTouchPoints: 5, standalone: false });

  it("굳은 차단은 다시 시도를 권하지 않는다", () => {
    const guide = micRecoveryGuide("permission_blocked", chrome);
    equal(guide.retryable, false);
    equal(guide.needsSettings, true);
    ok(guide.steps.length > 0);
  });

  it("창을 닫은 것은 다시 시도가 통한다", () => {
    const guide = micRecoveryGuide("permission_dismissed", chrome);
    equal(guide.retryable, true);
    equal(guide.needsSettings, false);
  });

  it("기기마다 안내 경로가 다르다", () => {
    const win = micRecoveryGuide("permission_blocked", chrome).steps.join(" ");
    const iphone = micRecoveryGuide("permission_blocked", ios).steps.join(" ");

    ok(win.includes("주소창"));
    ok(iphone.includes("Safari"));
    ok(iphone !== win);
  });

  it("인앱 브라우저는 권한 오류의 결론이 하나다 — 다른 브라우저로 열기", () => {
    const guide = micRecoveryGuide("permission_blocked", kakao);
    equal(guide.retryable, false);
    equal(guide.needsSettings, false);
    ok(guide.steps.join(" ").includes("Safari로 열기"));
  });

  it("OS 차단은 브라우저 설정이 아니라 시스템 설정으로 보낸다", () => {
    const guide = micRecoveryGuide("system_denied", chrome);
    ok(guide.steps.join(" ").includes("개인 정보"));
    equal(guide.retryable, false);
  });

  it("모든 코드가 원인과 안내를 갖는다", () => {
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
      ok(guide.cause.length > 0, `${code} 원인 없음`);
      ok(guide.steps.length > 0, `${code} 안내 없음`);
      ok(micErrorTitle(code).length > 0, `${code} 제목 없음`);
    }
  });
});

describe("isPermissionCode", () => {
  it("권한 계열만 참", () => {
    ok(isPermissionCode("permission_blocked"));
    ok(isPermissionCode("system_denied"));
    equal(isPermissionCode("device_busy"), false);
    equal(isPermissionCode("interrupted"), false);
  });
});
