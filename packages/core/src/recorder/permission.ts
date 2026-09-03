/**
 * 마이크 권한 진단 — 왜 막혔는지, 이 기기에서 무엇을 눌러야 풀리는지.
 *
 * ## 왜 따로 있나
 *
 * `getUserMedia` 가 던지는 것은 대부분 `NotAllowedError` 하나다. 그런데
 * 사용자가 실제로 해야 할 일은 상황마다 전혀 다르다.
 *
 * - 프롬프트를 그냥 닫았다      → 다시 누르면 또 물어본다
 * - "차단" 을 눌렀다            → 주소창 설정을 열어야 한다. 다시 눌러도 안 뜬다
 * - OS 개인정보 설정에서 껐다   → 브라우저 설정이 아니라 시스템 설정이다
 * - 카카오톡 인앱 브라우저다    → 무엇을 눌러도 안 된다. 다른 브라우저로 열어야 한다
 *
 * 이걸 전부 "마이크 사용이 거부되었습니다" 로 뭉뚱그리면 사용자는 같은 버튼을
 * 반복해서 누르다 포기한다. 녹음이 제품의 전부인 앱에서 이건 이탈이다.
 *
 * ## 브라우저별 사정
 *
 * | | Permissions API `microphone` | 프롬프트 재노출 |
 * |---|---|---|
 * | Chrome / Edge / Samsung | 지원 | 차단하면 안 뜸 |
 * | Safari (macOS · iOS)    | **미지원** — `query` 가 던지거나 거부 | 매번 물어보기도 함 |
 * | Firefox                 | 이름을 몰라 던진다 | 세션 단위 기억 |
 *
 * 그래서 상태를 **모른다(`unknown`)** 는 것을 1급 값으로 둔다. Safari 에서
 * "차단됨" 이라고 단정하면 실제로는 물어볼 수 있는 상황에서 길을 막아 버린다.
 */

export type MicPermissionState = "granted" | "prompt" | "denied" | "unknown";

export type BrowserKind = "chrome" | "edge" | "safari" | "firefox" | "samsung" | "other";
export type EngineKind = "blink" | "webkit" | "gecko" | "other";
export type OsKind = "ios" | "android" | "macos" | "windows" | "other";

export interface Platform {
  browser: BrowserKind;
  /** iOS 는 어떤 브라우저를 깔아도 WebKit 이다. 권한 안내는 엔진을 따라간다. */
  engine: EngineKind;
  os: OsKind;
  mobile: boolean;
  /** 홈 화면에서 띄운 PWA */
  standalone: boolean;
  /** 카카오톡·인스타 같은 인앱 브라우저 */
  webview: boolean;
}

/**
 * 화면에 그대로 박히지 않는, **로케일-프리 문안 지시자**.
 *
 * `packages/core` 는 프레임워크·i18n 비의존이어야 한다(프로젝트 규칙 4). 그래서
 * 여기서는 번역된 문자열이 아니라 **안정적인 키**(어떤 안내인지)와 **보간 파라미터**
 * (기기·상황에 따라 달라지는 값)만 낸다. 실제 번역은 UI 셸이 `t()` 로 한다 —
 * `@core/domain` 의 `VIEW_SCOPES` 를 web 이 `visibility.scopes.{mode}` 키로 렌더하는
 * 것과 같은 경계다.
 *
 * `key` 는 네임스페이스 없는 순수 키다(예: `cause.permission_blocked`). 카탈로그
 * 접두사(`recorder.guide.`)는 셸이 붙인다 — core 가 카탈로그 레이아웃을 알 필요가 없다.
 */
export interface GuideMessage {
  /** 안정적인 로케일-프리 카탈로그 키. */
  key: string;
  /** 보간 파라미터. 로케일과 무관한 값만(브라우저 메뉴명·개수 등). */
  params?: Record<string, string | number>;
}

export interface RecoveryGuide {
  /** 무엇이 막았는지 한 줄로. */
  cause: GuideMessage;
  /** 이 기기에서 순서대로 할 일. 비어 있으면 안내할 조작이 없다는 뜻. */
  steps: GuideMessage[];
  /**
   * 페이지 안에서 "다시 시도" 가 의미 있는가.
   *
   * 굳어버린 차단에서 이걸 켜 두면 사용자는 같은 버튼을 계속 누른다.
   */
  retryable: boolean;
  /** 브라우저·OS 설정을 직접 열어야 하는가. */
  needsSettings: boolean;
}

/** `GuideMessage` 를 짧게 만든다. 파라미터가 없으면 키만 담는다. */
function m(key: string, params?: Record<string, string | number>): GuideMessage {
  return params ? { key, params } : { key };
}

// ── 플랫폼 판별 ────────────────────────────────────────────

/** 인앱 브라우저 표식. 국내 트래픽 비중이 큰 것부터. */
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
 * UA 로 플랫폼을 읽는다.
 *
 * UA 스니핑은 원래 나쁜 습관이지만, **권한 설정 UI 의 위치**는 UA 말고 알 길이 없다.
 * 기능 판별(`navigator.permissions` 유무)과 섞지 않고 여기서만 쓴다 —
 * 여기서 틀려도 나빠지는 것은 안내 문구뿐이고 동작은 그대로다.
 */
export function detectPlatform(
  ua: string = typeof navigator !== "undefined" ? navigator.userAgent : "",
  hints: { maxTouchPoints?: number; standalone?: boolean } = {},
): Platform {
  const s = ua.toLowerCase();

  const touch =
    hints.maxTouchPoints ??
    (typeof navigator !== "undefined" ? (navigator.maxTouchPoints ?? 0) : 0);

  // iPadOS 13+ 는 데스크톱 Safari 인 척한다. 터치 포인트로만 갈린다.
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

  // 순서가 중요하다 — Edge 도 Samsung 도 UA 에 "chrome" 을 달고 다닌다.
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

  // iOS 에서는 Chrome(CriOS)·Firefox(FxiOS)도 전부 WebKit 이다.
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
  // 안드로이드 WebView 는 UA 에 "; wv" 를 붙인다.
  const androidWebView = android && /;\s*wv\b/.test(s);
  // iOS 인앱 브라우저는 Safari 토큰을 떼고 다닌다 (홈 화면 PWA 도 마찬가지라 제외).
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

// ── 권한 상태 조회 ─────────────────────────────────────────

type MicPermissionStatus = PermissionStatus & { name?: string };

function permissionsApi(): Permissions | null {
  if (typeof navigator === "undefined") return null;
  const api = navigator.permissions;
  return typeof api?.query === "function" ? api : null;
}

/**
 * 지금 마이크 권한이 어떤 상태인가.
 *
 * **모르면 `unknown` 이다.** Safari 는 `microphone` 이름을 모르고
 * (`TypeError`), 어떤 브라우저는 Promise 를 거부한다. 둘 다 "차단됨" 이 아니다 —
 * 거기서 차단으로 단정하면 물어볼 수 있는 사용자의 길까지 막는다.
 */
export async function queryMicPermission(): Promise<MicPermissionState> {
  const status = await queryMicPermissionStatus();
  return readPermissionState(status);
}

async function queryMicPermissionStatus(): Promise<MicPermissionStatus | null> {
  const api = permissionsApi();
  if (!api) return null;

  try {
    // 표준 이름은 "microphone". 타입 정의가 좁아 캐스팅한다.
    return (await api.query({ name: "microphone" as PermissionName })) as MicPermissionStatus;
  } catch {
    // Safari: TypeError, 일부 구형: 거부. 어느 쪽도 판단 근거가 못 된다.
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
 * 권한 상태가 바뀌면 알려준다. 구독을 끊는 함수를 돌려준다.
 *
 * 사용자가 **다른 탭의 브라우저 설정에서** 차단을 풀었을 때 이 화면이 그대로
 * "차단됨" 을 붙들고 있으면, 고쳐 놓고도 새로고침해야 한다는 걸 알 수 없다.
 *
 * Safari 는 이벤트를 주지 않는다. 그쪽은 `unknown` 으로 시작해 조용히 아무 일도
 * 하지 않는다 — 구독자는 콜백이 안 올 수 있다는 전제로 써야 한다.
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

// ── 오류 분류 ──────────────────────────────────────────────

/** 권한 계열 코드인가 — 세션 정리·버튼 잠금 판단에 쓴다. */
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
 * `getUserMedia` 의 예외를 우리 코드로 옮긴다.
 *
 * 이름만으로는 부족하다. Chrome 은 다섯 가지 상황을 전부 `NotAllowedError` 로
 * 주고 **메시지로만** 구분한다:
 *
 * - `Permission denied`              — 사용자가 차단을 눌렀다
 * - `Permission dismissed`           — 프롬프트를 그냥 닫았다 (다시 물어본다)
 * - `Permission denied by system`    — OS 개인정보 설정에서 브라우저가 막혔다
 * - `... disallowed by permissions policy` — iframe `allow` 속성이 없다
 *
 * 메시지 문구는 브라우저 버전에 따라 바뀔 수 있다. 그래서 **못 알아보면
 * 일반 `permission_denied` 로 떨어진다** — 안내가 덜 구체적일 뿐 틀리지는 않는다.
 */
export function classifyMediaError(error: unknown): RecorderErrorCodeLike {
  const err = (error ?? {}) as DomLikeError;
  const name = err.name ?? "";
  const message = (err.message ?? "").toLowerCase();

  switch (name) {
    case "NotAllowedError":
    case "PermissionDeniedError": // 구형 Chrome/WebKit
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

    // 장치는 있는데 열 수 없다 — 다른 앱 점유, 드라이버 오류, iOS 통화 중.
    case "NotReadableError":
    case "TrackStartError":
    case "AbortError":
      return "device_busy";

    case "TypeError":
      // 제약 객체가 비었을 때만 나온다. 우리 버그지 사용자 잘못이 아니다.
      return "unknown";

    default:
      return "unknown";
  }
}

/** `types.ts` 의 `RecorderErrorCode` 와 같은 집합. 순환 import 를 피하려고 여기서 좁게 다시 쓴다. */
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
 * 브라우저가 보고한 권한 상태로 분류를 다듬는다.
 *
 * 프롬프트를 닫은 것과 차단을 누른 것은 Chrome 밖에서는 구별되지 않는다.
 * 그런데 Permissions API 는 그 뒤의 **결과 상태**를 안다.
 *
 * - `denied`  → 굳었다. 다시 눌러도 프롬프트가 안 뜬다 → `permission_blocked`
 * - `prompt`  → 아직 물어볼 수 있다 → `permission_dismissed`
 * - `unknown` → Safari. 원래 분류를 그대로 둔다
 */
export function refinePermissionCode(
  code: RecorderErrorCodeLike,
  state: MicPermissionState,
): RecorderErrorCodeLike {
  // OS·iframe 차단은 사이트 권한 상태와 무관하다. 덮어쓰면 안내가 틀어진다.
  if (code === "system_denied" || code === "embed_blocked") return code;
  if (!isPermissionCode(code)) return code;

  if (state === "denied") return "permission_blocked";
  if (state === "prompt") return "permission_dismissed";
  return code;
}

// ── 안내문 ────────────────────────────────────────────────

/** 브라우저 사이트 권한을 여는 길. 안내의 절반은 "어디를 누르는가" 다. */
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

  // Edge 도 Samsung 도 Chromium 이지만, 설정 메뉴 이름은 브라우저마다 다르다.
  const menu = browser === "edge" ? "Edge" : "Chrome";
  return [
    m("step.siteChromiumIcon"),
    m("step.siteChromiumAllow", { menu }),
    m("step.refreshPage"),
  ];
}

/** OS 개인정보 설정을 여는 길. 브라우저 설정을 아무리 만져도 여기서 막히면 안 열린다. */
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
 * 오류 코드 + 이 기기 = 사용자가 할 일.
 *
 * 문구를 컴포넌트에 흩어 두지 않는다. 데스크톱 화면과 모바일 화면이 각자
 * 다른 안내를 하기 시작하면 어느 쪽이 맞는지 아무도 모르게 된다.
 */
export function micRecoveryGuide(
  code: RecorderErrorCodeLike,
  platform: Platform = detectPlatform(),
): RecoveryGuide {
  // 인앱 브라우저는 코드가 무엇이든 결론이 같다 — 여기서는 못 고친다.
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
        // Safari 는 차단 여부를 알려주지 않는다. 한 번 더 눌러 보는 것이 실제로 통한다.
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
 * 오류 코드의 한 줄 요약 키. 알림 띠 제목으로 쓴다.
 *
 * 제목은 오직 코드에만 달렸다(플랫폼 무관). 그래서 키를 `title.{code}` 로 바로
 * 낸다 — 셸 카탈로그의 `recorder.guide.title.{code}` 에 모든 코드의 제목이 있다.
 */
export function micErrorTitle(code: RecorderErrorCodeLike): GuideMessage {
  return m(`title.${code}`);
}
