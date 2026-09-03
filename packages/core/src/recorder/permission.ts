/**
 * Microphone permission diagnosis — why it was blocked, and what to press on
 * this device to unblock it.
 *
 * ## Why this exists
 *
 * What `getUserMedia` throws is mostly just `NotAllowedError`. Yet what the
 * user actually needs to do differs completely by situation.
 *
 * - Dismissed the prompt          → pressing again asks again
 * - Pressed "Block"               → must open the address-bar settings; pressing again shows nothing
 * - Turned it off in OS privacy   → system settings, not browser settings
 * - KakaoTalk in-app browser      → nothing they press will work; must open in another browser
 *
 * Lumping all of this into "microphone access was denied" leaves the user
 * pressing the same button until they give up. In an app where recording is
 * the whole product, that is churn.
 *
 * ## Per-browser realities
 *
 * | | Permissions API `microphone` | Prompt re-display |
 * |---|---|---|
 * | Chrome / Edge / Samsung | supported | never shown once blocked |
 * | Safari (macOS · iOS)    | **unsupported** — `query` throws or rejects | may ask every time |
 * | Firefox                 | throws, name unknown | remembered per session |
 *
 * So **not knowing (`unknown`)** is a first-class value. Declaring "blocked"
 * on Safari would wall off users who could actually still be asked.
 */

export type MicPermissionState = "granted" | "prompt" | "denied" | "unknown";

export type BrowserKind = "chrome" | "edge" | "safari" | "firefox" | "samsung" | "other";
export type EngineKind = "blink" | "webkit" | "gecko" | "other";
export type OsKind = "ios" | "android" | "macos" | "windows" | "other";

export interface Platform {
  browser: BrowserKind;
  /** On iOS every browser is WebKit. Permission guidance follows the engine. */
  engine: EngineKind;
  os: OsKind;
  mobile: boolean;
  /** PWA launched from the home screen */
  standalone: boolean;
  /** In-app browser like KakaoTalk or Instagram */
  webview: boolean;
}

/**
 * A **locale-free wording designator** — never rendered to the screen as-is.
 *
 * `packages/core` must stay framework- and i18n-agnostic (project rule 4).
 * So instead of translated strings, this emits only a **stable key** (which
 * guidance it is) and **interpolation params** (values that vary by device
 * or situation). The UI shell does the actual translation with `t()` — the
 * same boundary as web rendering `@core/domain`'s `VIEW_SCOPES` through
 * `visibility.scopes.{mode}` keys.
 *
 * `key` is a pure, namespace-free key (e.g. `cause.permission_blocked`).
 * The catalog prefix (`recorder.guide.`) is added by the shell — core need
 * not know the catalog layout.
 */
export interface GuideMessage {
  /** Stable, locale-free catalog key. */
  key: string;
  /** Interpolation params. Locale-independent values only (browser menu names, counts, etc.). */
  params?: Record<string, string | number>;
}

export interface RecoveryGuide {
  /** One line saying what blocked it. */
  cause: GuideMessage;
  /** Steps to take, in order, on this device. Empty means there is nothing to instruct. */
  steps: GuideMessage[];
  /**
   * Does "try again" mean anything within the page?
   *
   * Leaving this on for a hardened block keeps the user pressing the same
   * button.
   */
  retryable: boolean;
  /** Must browser/OS settings be opened directly? */
  needsSettings: boolean;
}

/** Shorthand for `GuideMessage`. Carries only the key when there are no params. */
function m(key: string, params?: Record<string, string | number>): GuideMessage {
  return params ? { key, params } : { key };
}

// ── Platform detection ───────────────────────────────────

/** In-app browser markers. Highest local traffic share first. */
const IN_APP_MARKERS = [
  "kakaotalk",
  "naver(inapp",
  "naver ",
  "whale",
  "line/",
  "instagram",
  "fban",
  "fbav",
  "fb_iab",
  "everytimeapp",
  "daumapps",
  "trill",
  "musical_ly",
];

/**
 * Reads the platform from the UA.
 *
 * UA sniffing is a bad habit in general, but **where the permission settings
 * UI lives** cannot be learned any other way. It is used only here, never
 * mixed with feature detection (`navigator.permissions` presence) — a wrong
 * guess here only degrades the guidance wording; behavior stays the same.
 */
export function detectPlatform(
  ua: string = typeof navigator !== "undefined" ? navigator.userAgent : "",
  hints: { maxTouchPoints?: number; standalone?: boolean } = {},
): Platform {
  const s = ua.toLowerCase();

  const touch =
    hints.maxTouchPoints ??
    (typeof navigator !== "undefined" ? (navigator.maxTouchPoints ?? 0) : 0);

  // iPadOS 13+ pretends to be desktop Safari. Only touch points tell them apart.
  const iPadDesktopUa = s.includes("macintosh") && touch > 1;
  const ios = /iphone|ipad|ipod/.test(s) || iPadDesktopUa;
  const android = s.includes("android");

  const os: OsKind = ios
    ? "ios"
    : android
      ? "android"
      : s.includes("windows")
        ? "windows"
        : s.includes("mac os")
          ? "macos"
          : "other";

  // Order matters — both Edge and Samsung carry "chrome" in their UA.
  const browser: BrowserKind = /edg[ea]?\//.test(s)
    ? "edge"
    : s.includes("samsungbrowser")
      ? "samsung"
      : /fxios|firefox/.test(s)
        ? "firefox"
        : /crios|chrome|chromium/.test(s)
          ? "chrome"
          : s.includes("safari") || ios
            ? "safari"
            : "other";

  // On iOS, Chrome (CriOS) and Firefox (FxiOS) are all WebKit too.
  const engine: EngineKind = ios
    ? "webkit"
    : browser === "firefox"
      ? "gecko"
      : browser === "safari"
        ? "webkit"
        : browser === "other"
          ? "other"
          : "blink";

  const standalone =
    hints.standalone ??
    (typeof window !== "undefined" &&
      (window.matchMedia?.("(display-mode: standalone)")?.matches === true ||
        (navigator as unknown as { standalone?: boolean })?.standalone === true));

  const inAppMarker = IN_APP_MARKERS.some((marker) => s.includes(marker));
  // Android WebView appends "; wv" to the UA.
  const androidWebView = android && /;\s*wv\b/.test(s);
  // iOS in-app browsers drop the Safari token (so do home-screen PWAs, hence the exclusion).
  const iosWebView = ios && !s.includes("safari") && !standalone;

  return {
    browser,
    engine,
    os,
    mobile: ios || android || s.includes("mobile"),
    standalone: standalone === true,
    webview: inAppMarker || androidWebView || iosWebView,
  };
}

// ── Permission state queries ─────────────────────────────

type MicPermissionStatus = PermissionStatus & { name?: string };

function permissionsApi(): Permissions | null {
  if (typeof navigator === "undefined") return null;
  const api = navigator.permissions;
  return typeof api?.query === "function" ? api : null;
}

/**
 * What state is the microphone permission in right now?
 *
 * **When we cannot tell, it is `unknown`.** Safari does not know the
 * `microphone` name (`TypeError`), and some browsers reject the Promise.
 * Neither means "blocked" — declaring blocked there walls off users who
 * could still be asked.
 */
export async function queryMicPermission(): Promise<MicPermissionState> {
  const status = await queryMicPermissionStatus();
  return readPermissionState(status);
}

async function queryMicPermissionStatus(): Promise<MicPermissionStatus | null> {
  const api = permissionsApi();
  if (!api) return null;

  try {
    // The standard name is "microphone". The type definition is narrow, so we cast.
    return (await api.query({ name: "microphone" as PermissionName })) as MicPermissionStatus;
  } catch {
    // Safari: TypeError; some older browsers: rejection. Neither is evidence either way.
    return null;
  }
}

function readPermissionState(status: MicPermissionStatus | null): MicPermissionState {
  switch (status?.state) {
    case "granted":
      return "granted";
    case "denied":
      return "denied";
    case "prompt":
      return "prompt";
    default:
      return "unknown";
  }
}

/**
 * Notifies when the permission state changes. Returns an unsubscribe
 * function.
 *
 * When the user lifts the block **from browser settings in another tab** and
 * this screen keeps clinging to "blocked", they have no way to know a
 * refresh is needed even though they fixed it.
 *
 * Safari emits no events. There it starts as `unknown` and quietly does
 * nothing — subscribers must assume the callback may never come.
 */
export function watchMicPermission(
  onChange: (state: MicPermissionState) => void,
): () => void {
  let status: MicPermissionStatus | null = null;
  let stopped = false;

  const handler = () => onChange(readPermissionState(status));

  void queryMicPermissionStatus().then((result) => {
    if (stopped) {
      return;
    }

    status = result;
    if (!result) return;

    onChange(readPermissionState(result));
    result.addEventListener?.("change", handler);
  });

  return () => {
    stopped = true;
    status?.removeEventListener?.("change", handler);
    status = null;
  };
}

// ── Error classification ─────────────────────────────────

/** Is this a permission-family code? Used for session cleanup and button locking. */
export const PERMISSION_CODES = [
  "permission_denied",
  "permission_blocked",
  "permission_dismissed",
  "system_denied",
  "embed_blocked",
] as const;

export type PermissionErrorCode = (typeof PERMISSION_CODES)[number];

export function isPermissionCode(code: string): code is PermissionErrorCode {
  return (PERMISSION_CODES as readonly string[]).includes(code);
}

interface DomLikeError {
  name?: string;
  message?: string;
  constraint?: string;
}

/**
 * Maps `getUserMedia` exceptions to our codes.
 *
 * The name alone is not enough. Chrome reports five situations all as
 * `NotAllowedError` and distinguishes them **only by message**:
 *
 * - `Permission denied`              — the user pressed Block
 * - `Permission dismissed`           — the prompt was dismissed (asking again works)
 * - `Permission denied by system`    — the browser is blocked in OS privacy settings
 * - `... disallowed by permissions policy` — the iframe lacks the `allow` attribute
 *
 * Message wording can change across browser versions. So **anything
 * unrecognized falls back to plain `permission_denied`** — the guidance is
 * less specific, but never wrong.
 */
export function classifyMediaError(error: unknown): RecorderErrorCodeLike {
  const err = (error ?? {}) as DomLikeError;
  const name = err.name ?? "";
  const message = (err.message ?? "").toLowerCase();

  switch (name) {
    case "NotAllowedError":
    case "PermissionDeniedError": // legacy Chrome/WebKit
    case "SecurityError": {
      if (/permissions?\s+policy|feature\s*policy|disallowed by/.test(message)) {
        return "embed_blocked";
      }
      if (/by system|system-?level|operating system/.test(message)) return "system_denied";
      if (/dismiss/.test(message)) return "permission_dismissed";
      return "permission_denied";
    }

    case "NotFoundError":
    case "DevicesNotFoundError":
      return "no_device";

    case "OverconstrainedError":
    case "ConstraintNotSatisfiedError":
      return "device_unavailable";

    // The device exists but cannot be opened — held by another app, driver error, iOS mid-call.
    case "NotReadableError":
    case "TrackStartError":
    case "AbortError":
      return "device_busy";

    case "TypeError":
      // Only occurs when the constraints object is empty. Our bug, not the user's fault.
      return "unknown";

    default:
      return "unknown";
  }
}

/** Same set as `RecorderErrorCode` in `types.ts`. Redeclared narrowly here to avoid a circular import. */
type RecorderErrorCodeLike =
  | "unsupported"
  | "insecure_context"
  | "permission_denied"
  | "permission_blocked"
  | "permission_dismissed"
  | "system_denied"
  | "embed_blocked"
  | "no_device"
  | "device_unavailable"
  | "device_busy"
  | "interrupted"
  | "unknown";

/**
 * Refines the classification using the browser-reported permission state.
 *
 * Outside Chrome, dismissing the prompt and pressing Block are
 * indistinguishable. But the Permissions API knows the **resulting state**
 * afterward.
 *
 * - `denied`  → hardened; pressing again shows no prompt → `permission_blocked`
 * - `prompt`  → can still be asked → `permission_dismissed`
 * - `unknown` → Safari; keep the original classification
 */
export function refinePermissionCode(
  code: RecorderErrorCodeLike,
  state: MicPermissionState,
): RecorderErrorCodeLike {
  // OS and iframe blocks are unrelated to the site permission state. Overwriting skews the guidance.
  if (code === "system_denied" || code === "embed_blocked") return code;
  if (!isPermissionCode(code)) return code;

  if (state === "denied") return "permission_blocked";
  if (state === "prompt") return "permission_dismissed";
  return code;
}

// ── Guidance ─────────────────────────────────────────────

/** The path to the browser's site permissions. Half of the guidance is "where to press". */
function siteSettingsSteps(platform: Platform): GuideMessage[] {
  const { engine, os, browser } = platform;

  if (os === "ios") {
    return [m("step.siteIosAa"), m("step.siteIosSettings"), m("step.refreshPage")];
  }

  if (engine === "webkit") {
    return [m("step.siteWebkitMenu"), m("step.refreshPage")];
  }

  if (engine === "gecko") {
    return [m("step.siteGeckoLock"), m("step.refreshPage")];
  }

  if (os === "android") {
    return [
      m("step.siteAndroidLock"),
      m("step.siteAndroidAppSettings"),
      m("step.refreshPage"),
    ];
  }

  // Edge and Samsung are both Chromium, but the settings menu name differs per browser.
  const menu = browser === "edge" ? "Edge" : "Chrome";
  return [
    m("step.siteChromiumIcon"),
    m("step.siteChromiumAllow", { menu }),
    m("step.refreshPage"),
  ];
}

/** The path to OS privacy settings. No amount of browser fiddling helps if it is blocked here. */
function systemSettingsSteps(platform: Platform): GuideMessage[] {
  switch (platform.os) {
    case "macos":
      return [
        m("step.systemMacosOpen"),
        m("step.systemMacosEnable"),
        m("step.systemMacosRestart"),
      ];
    case "windows":
      return [
        m("step.systemWindowsOpen"),
        m("step.systemWindowsEnable"),
        m("step.systemWindowsRestart"),
      ];
    case "ios":
      return [m("step.systemIosOpen"), m("step.systemIosEnable"), m("step.refreshPage")];
    case "android":
      return [m("step.systemAndroidOpen"), m("step.refreshPage")];
    default:
      return [m("step.systemOtherOpen"), m("step.systemOtherRestart")];
  }
}

function openInBrowserSteps(platform: Platform): GuideMessage[] {
  return platform.os === "ios"
    ? [
        m("step.openInBrowserIosMenu"),
        m("step.openInBrowserIosSafari"),
        m("step.openInBrowserIosRecord"),
      ]
    : [
        m("step.openInBrowserOtherMenu"),
        m("step.openInBrowserOtherChrome"),
        m("step.openInBrowserOtherRecord"),
      ];
}

/**
 * Error code + this device = what the user should do.
 *
 * The wording is not scattered across components. Once the desktop screen
 * and the mobile screen start giving different guidance, nobody knows which
 * one is right.
 */
export function micRecoveryGuide(
  code: RecorderErrorCodeLike,
  platform: Platform = detectPlatform(),
): RecoveryGuide {
  // In an in-app browser the conclusion is the same whatever the code — it cannot be fixed here.
  if (platform.webview && isPermissionCode(code)) {
    return {
      cause: m("cause.webview"),
      steps: openInBrowserSteps(platform),
      retryable: false,
      needsSettings: false,
    };
  }

  switch (code) {
    case "permission_dismissed":
      return {
        cause: m("cause.permission_dismissed"),
        steps: [m("step.dismissedRetry"), m("step.dismissedAllow")],
        retryable: true,
        needsSettings: false,
      };

    case "permission_blocked":
      return {
        cause: m("cause.permission_blocked"),
        steps: siteSettingsSteps(platform),
        retryable: false,
        needsSettings: true,
      };

    case "permission_denied":
      return {
        cause: m("cause.permission_denied"),
        steps: [
          m("step.deniedRetry"),
          ...(platform.engine === "webkit" ? [m("step.deniedWebkitHint")] : []),
          ...siteSettingsSteps(platform),
        ],
        // Safari never says whether it is blocked. Pressing once more actually works.
        retryable: platform.engine === "webkit",
        needsSettings: true,
      };

    case "system_denied":
      return {
        cause: m("cause.system_denied"),
        steps: systemSettingsSteps(platform),
        retryable: false,
        needsSettings: true,
      };

    case "embed_blocked":
      return {
        cause: m("cause.embed_blocked"),
        steps: [m("step.embedOpenNewTab")],
        retryable: false,
        needsSettings: false,
      };

    case "device_busy":
      return {
        cause: m("cause.device_busy"),
        steps: platform.mobile
          ? [m("step.busyMobileEndCall"), m("step.busyMobileCloseApps"), m("step.retry")]
          : [m("step.busyDesktopCloseApps"), m("step.busyDesktopCloseTabs"), m("step.retry")],
        retryable: true,
        needsSettings: false,
      };

    case "device_unavailable":
      return {
        cause: m("cause.device_unavailable"),
        steps: [m("step.unavailableBluetooth"), m("step.unavailableSwitchDefault")],
        retryable: false,
        needsSettings: false,
      };

    case "no_device":
      return {
        cause: m("cause.no_device"),
        steps: platform.mobile
          ? [m("step.noDeviceMobileReplug"), m("step.retry")]
          : [
              m("step.noDeviceDesktopCheck"),
              m("step.noDeviceDesktopOsSound"),
              m("step.retry"),
            ],
        retryable: true,
        needsSettings: false,
      };

    case "insecure_context":
      return {
        cause: m("cause.insecure_context"),
        steps: [m("step.insecureHttps"), m("step.insecureLocalhost")],
        retryable: false,
        needsSettings: false,
      };

    case "unsupported":
      return {
        cause: platform.webview ? m("cause.unsupported_webview") : m("cause.unsupported"),
        steps: platform.webview
          ? openInBrowserSteps(platform)
          : platform.os === "ios"
            ? [m("step.unsupportedIos")]
            : [m("step.unsupportedOther")],
        retryable: false,
        needsSettings: false,
      };

    case "interrupted":
      return {
        cause: m("cause.interrupted"),
        steps: platform.mobile
          ? [m("step.interruptedMobileAfterCall"), m("step.interruptedMobileKeepScreen")]
          : [m("step.interruptedDesktopCheck")],
        retryable: true,
        needsSettings: false,
      };

    default:
      return {
        cause: m("cause.unknown"),
        steps: [m("step.retry"), m("step.defaultRefreshFail")],
        retryable: true,
        needsSettings: false,
      };
  }
}

/**
 * One-line summary key for an error code. Used as the notification banner
 * title.
 *
 * The title depends only on the code (platform-independent), so the key is
 * emitted directly as `title.{code}` — the shell catalog holds every code's
 * title under `recorder.guide.title.{code}`.
 */
export function micErrorTitle(code: RecorderErrorCodeLike): GuideMessage {
  return m(`title.${code}`);
}
