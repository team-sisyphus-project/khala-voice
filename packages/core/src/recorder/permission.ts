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

export interface RecoveryGuide {
  /** 무엇이 막았는지 한 줄로. */
  cause: string;
  /** 이 기기에서 순서대로 할 일. 비어 있으면 안내할 조작이 없다는 뜻. */
  steps: string[];
  /**
   * 페이지 안에서 "다시 시도" 가 의미 있는가.
   *
   * 굳어버린 차단에서 이걸 켜 두면 사용자는 같은 버튼을 계속 누른다.
   */
  retryable: boolean;
  /** 브라우저·OS 설정을 직접 열어야 하는가. */
  needsSettings: boolean;
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
function siteSettingsSteps(platform: Platform): string[] {
  const { engine, os, browser } = platform;

  if (os === "ios") {
    return [
      "주소창 왼쪽의 'ᴀA' 를 누르고 [웹사이트 설정] → [마이크] 를 [허용] 으로 바꿉니다.",
      "그래도 안 되면 iOS [설정] → [Safari] → [마이크] 를 [확인] 또는 [허용] 으로 바꿉니다.",
      "설정을 바꾼 뒤 이 페이지를 새로고침합니다.",
    ];
  }

  if (engine === "webkit") {
    return [
      "Safari 메뉴 → [설정] → [웹사이트] → [마이크] 에서 이 사이트를 [허용] 으로 바꿉니다.",
      "설정을 바꾼 뒤 이 페이지를 새로고침합니다.",
    ];
  }

  if (engine === "gecko") {
    return [
      "주소창 왼쪽 자물쇠를 누르고 [마이크] 옆의 차단 표시(✕)를 눌러 해제합니다.",
      "설정을 바꾼 뒤 이 페이지를 새로고침합니다.",
    ];
  }

  if (os === "android") {
    return [
      "주소창 왼쪽 자물쇠 → [권한] → [마이크] 를 [허용] 으로 바꿉니다.",
      "안드로이드 [설정] → [애플리케이션] → 브라우저 → [권한] → [마이크] 도 허용인지 확인합니다.",
      "설정을 바꾼 뒤 이 페이지를 새로고침합니다.",
    ];
  }

  const menu = browser === "edge" ? "Edge" : "Chrome";
  return [
    `주소창 오른쪽 끝의 차단된 마이크 아이콘(또는 주소창 왼쪽 아이콘)을 누릅니다.`,
    `[마이크]를 [허용]으로 바꿉니다. (${menu} 설정 → 개인 정보 보호 및 보안 → 사이트 설정 → 마이크 에서도 바꿀 수 있습니다.)`,
    "설정을 바꾼 뒤 이 페이지를 새로고침합니다.",
  ];
}

/** OS 개인정보 설정을 여는 길. 브라우저 설정을 아무리 만져도 여기서 막히면 안 열린다. */
function systemSettingsSteps(platform: Platform): string[] {
  switch (platform.os) {
    case "macos":
      return [
        "[시스템 설정] → [개인정보 보호 및 보안] → [마이크] 를 엽니다.",
        "브라우저 항목을 켭니다.",
        "브라우저를 완전히 종료했다가 다시 엽니다.",
      ];
    case "windows":
      return [
        "[설정] → [개인 정보 및 보안] → [마이크] 를 엽니다.",
        "[앱이 마이크에 액세스하도록 허용] 과 [데스크톱 앱...] 을 모두 켭니다.",
        "브라우저를 다시 시작합니다.",
      ];
    case "ios":
      return [
        "iOS [설정] → [개인정보 보호 및 보안] → [마이크] 를 엽니다.",
        "브라우저 항목을 켭니다.",
        "이 페이지를 새로고침합니다.",
      ];
    case "android":
      return [
        "안드로이드 [설정] → [애플리케이션] → 브라우저 → [권한] → [마이크] 를 [허용] 으로 바꿉니다.",
        "이 페이지를 새로고침합니다.",
      ];
    default:
      return [
        "운영체제의 개인정보 설정에서 브라우저의 마이크 접근을 켭니다.",
        "브라우저를 다시 시작합니다.",
      ];
  }
}

function openInBrowserSteps(platform: Platform): string[] {
  return platform.os === "ios"
    ? [
        "오른쪽 아래(또는 위) [···] 메뉴를 누릅니다.",
        "[Safari로 열기] 를 누릅니다.",
        "Safari 에서 다시 녹음을 시작합니다.",
      ]
    : [
        "오른쪽 위 [⋮] 또는 [···] 메뉴를 누릅니다.",
        "[다른 브라우저로 열기] 또는 [Chrome으로 열기] 를 누릅니다.",
        "Chrome 에서 다시 녹음을 시작합니다.",
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
      cause: "인앱 브라우저에서는 마이크를 쓸 수 없습니다.",
      steps: openInBrowserSteps(platform),
      retryable: false,
      needsSettings: false,
    };
  }

  switch (code) {
    case "permission_dismissed":
      return {
        cause: "마이크 권한 창을 닫았습니다. 아직 허용도 차단도 아닙니다.",
        steps: [
          "[다시 시도] 를 누르면 권한 창이 한 번 더 뜹니다.",
          "창이 뜨면 [허용] 을 누릅니다.",
        ],
        retryable: true,
        needsSettings: false,
      };

    case "permission_blocked":
      return {
        cause: "이 사이트의 마이크가 차단되어 있습니다. 다시 눌러도 권한 창이 뜨지 않습니다.",
        steps: siteSettingsSteps(platform),
        retryable: false,
        needsSettings: true,
      };

    case "permission_denied":
      return {
        cause: "마이크 사용이 거부되었습니다.",
        steps: [
          "[다시 시도] 를 눌러 권한 창이 뜨는지 봅니다.",
          ...(platform.engine === "webkit"
            ? ["창이 뜨지 않으면 아래 방법으로 사이트 권한을 바꿉니다."]
            : []),
          ...siteSettingsSteps(platform),
        ],
        // Safari 는 차단 여부를 알려주지 않는다. 한 번 더 눌러 보는 것이 실제로 통한다.
        retryable: platform.engine === "webkit",
        needsSettings: true,
      };

    case "system_denied":
      return {
        cause: "운영체제 설정에서 브라우저의 마이크 접근이 꺼져 있습니다.",
        steps: systemSettingsSteps(platform),
        retryable: false,
        needsSettings: true,
      };

    case "embed_blocked":
      return {
        cause: "이 페이지가 다른 사이트 안에 삽입되어 있어 마이크가 막혔습니다.",
        steps: ["이 페이지를 새 탭에서 직접 엽니다."],
        retryable: false,
        needsSettings: false,
      };

    case "device_busy":
      return {
        cause: "마이크는 있지만 다른 앱이 쓰고 있어 열 수 없습니다.",
        steps: platform.mobile
          ? [
              "통화 중이라면 통화를 끝냅니다.",
              "다른 녹음·통화 앱을 완전히 종료합니다.",
              "[다시 시도] 를 누릅니다.",
            ]
          : [
              "화상회의·녹음 앱(줌·팀즈·디스코드 등)을 종료합니다.",
              "다른 탭에서 이 사이트나 회의 서비스를 열어 두었다면 닫습니다.",
              "[다시 시도] 를 누릅니다.",
            ],
        retryable: true,
        needsSettings: false,
      };

    case "device_unavailable":
      return {
        cause: "선택해 둔 마이크를 찾을 수 없습니다. 뽑혔거나 꺼진 것 같습니다.",
        steps: [
          "블루투스 헤드셋이라면 연결을 확인합니다.",
          "[기본 마이크로 바꾸기] 를 누르거나 녹음 설정에서 다른 마이크를 고릅니다.",
        ],
        retryable: false,
        needsSettings: false,
      };

    case "no_device":
      return {
        cause: "쓸 수 있는 마이크가 없습니다.",
        steps: platform.mobile
          ? ["헤드셋을 뺐다 다시 꽂아 봅니다.", "[다시 시도] 를 누릅니다."]
          : [
              "마이크나 헤드셋이 꽂혀 있는지 확인합니다.",
              "OS 사운드 설정에서 입력 장치가 잡히는지 확인합니다.",
              "[다시 시도] 를 누릅니다.",
            ],
        retryable: true,
        needsSettings: false,
      };

    case "insecure_context":
      return {
        cause: "HTTPS 가 아니면 브라우저가 마이크를 열어주지 않습니다.",
        steps: [
          "주소를 `https://` 로 바꿔 다시 접속합니다.",
          "실기기 테스트 중이라면 `localhost` 또는 https 터널 주소로 접속합니다.",
        ],
        retryable: false,
        needsSettings: false,
      };

    case "unsupported":
      return {
        cause: platform.webview
          ? "인앱 브라우저는 녹음을 지원하지 않습니다."
          : "이 브라우저는 녹음을 지원하지 않습니다.",
        steps: platform.webview
          ? openInBrowserSteps(platform)
          : platform.os === "ios"
            ? ["iOS 14.3 이상에서 Safari 로 접속합니다."]
            : ["최신 Chrome · Edge · Safari 로 접속합니다."],
        retryable: false,
        needsSettings: false,
      };

    case "interrupted":
      return {
        cause: "녹음 중 마이크 연결이 끊겼습니다. 그때까지의 녹음은 저장했습니다.",
        steps: platform.mobile
          ? [
              "통화가 끝난 뒤 다시 녹음을 시작합니다.",
              "긴 회의는 화면을 켜 둔 채로 두면 끊길 확률이 줄어듭니다.",
            ]
          : ["마이크 연결을 확인한 뒤 다시 녹음을 시작합니다."],
        retryable: true,
        needsSettings: false,
      };

    default:
      return {
        cause: "마이크를 열지 못했습니다.",
        steps: ["[다시 시도] 를 누릅니다.", "계속 실패하면 페이지를 새로고침합니다."],
        retryable: true,
        needsSettings: false,
      };
  }
}

/** 오류 코드의 한 줄 요약. 알림 띠 제목으로 쓴다. */
export function micErrorTitle(code: RecorderErrorCodeLike): string {
  switch (code) {
    case "permission_blocked":
      return "마이크가 차단되어 있습니다";
    case "permission_dismissed":
      return "마이크 권한을 받지 못했습니다";
    case "permission_denied":
      return "마이크 사용이 거부되었습니다";
    case "system_denied":
      return "시스템에서 마이크가 꺼져 있습니다";
    case "embed_blocked":
      return "삽입된 화면에서는 마이크를 쓸 수 없습니다";
    case "device_busy":
      return "마이크를 다른 앱이 쓰고 있습니다";
    case "device_unavailable":
      return "선택한 마이크를 찾을 수 없습니다";
    case "no_device":
      return "마이크를 찾지 못했습니다";
    case "insecure_context":
      return "보안 연결(HTTPS)이 아닙니다";
    case "unsupported":
      return "이 브라우저는 녹음을 지원하지 않습니다";
    case "interrupted":
      return "녹음이 중단되었습니다";
    default:
      return "녹음 오류";
  }
}
