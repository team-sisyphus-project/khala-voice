/**
 * 마이크 — **이 기기에만** 남는다.
 *
 * 마이크는 사람이 아니라 **자리**에 딸린 설정이다. 회의실 PC 는 늘 그 방의 USB
 * 마이크를 쓰고, 폰은 늘 내장 마이크를 쓴다. 계정에 매달아 기기 사이에
 * 따라다니게 하면 회의실에서 고른 마이크가 폰에서도 골라진 것처럼 보인다.
 *
 * **전사 언어는 여기 없다.** 그건 사람에 딸린 설정이라 계정에 있다
 * (`CurrentAccount.transcribe_language`). 기기를 바꿔도 따라와야 한다.
 */

export interface Prefs {
  /** 마이크 장치 ID. null 이면 브라우저·OS 기본 장치 */
  micDeviceId: string | null;
}

/**
 * 전사 언어 목록.
 *
 * Google STT v2 (Chirp) 가 화자분리와 함께 지원하는 것 위주로 골랐다.
 * 여기 없는 언어를 넣고 싶으면 전사 품질을 먼저 확인해야 한다 —
 * 화자분리는 언어마다 지원 여부가 다르다.
 *
 * 표시 이름은 여기 두지 않는다 — 선택된 UI 언어로 렌더해야 하므로
 * i18n 카탈로그(`language.names.<id>`)가 문자열의 단일 출처다. 여기는 STT
 * 코드(id)만 담는다.
 */
export const LANGUAGES = [
  { id: "ko-KR" },
  { id: "en-US" },
  { id: "en-GB" },
  { id: "ja-JP" },
  // 중국어는 `zh-*` 가 아니라 `cmn-*` 다 — Google STT v2 의 코드가 그렇다.
  // 문서(`docs/04-pipeline.md`)와 여기가 다르면 전사가 통째로 실패한다.
  { id: "cmn-Hans-CN" },
  { id: "cmn-Hant-TW" },
  { id: "es-ES" },
  { id: "fr-FR" },
  { id: "de-DE" },
  { id: "vi-VN" },
] as const;

/**
 * 브라우저 언어로도 못 정할 때의 값.
 *
 * 서버(`transcription_worker.ex`)의 기본값과 **같아야 한다** — 클라이언트가
 * 언어를 못 보낸 세션이 서버에서 다른 언어로 전사되면 안 된다.
 */
export const FALLBACK_LANGUAGE = "en-US";

/**
 * 브라우저 언어 → 전사 언어.
 *
 * 첫 방문자에게 고정값을 물리면 다른 언어권 사용자는 매 녹음마다 손으로 바꿔야
 * 하고, **한 번 잊으면 그 회의 전사는 통째로 버려진다** (크레딧은 나간다).
 * 그래서 접속한 브라우저의 언어를 따라간다.
 *
 * 지역까지 맞는 것이 있으면 그것을, 없으면 같은 언어의 대표를 고른다.
 * 아무것도 안 맞으면 **영어** — 오픈소스로 공개하는 서비스의 기본값이다.
 */
function detectLanguage(): string {
  if (typeof navigator === "undefined") return FALLBACK_LANGUAGE;

  const wanted = navigator.languages?.length ? navigator.languages : [navigator.language];

  for (const raw of wanted) {
    if (!raw) continue;

    const tag = raw.toLowerCase();

    // ko-KR 처럼 통째로 맞는 것
    const exact = LANGUAGES.find((l) => l.id.toLowerCase() === tag);
    if (exact) return exact.id;

    // zh-CN · zh-Hans 는 STT 코드가 cmn-* 이라 따로 짚는다
    if (tag.startsWith("zh")) {
      return tag.includes("tw") || tag.includes("hant") || tag.includes("hk")
        ? "cmn-Hant-TW"
        : "cmn-Hans-CN";
    }

    // en → en-US 처럼 언어만 맞는 것
    const base = tag.split("-")[0];
    const loose = LANGUAGES.find((l) => l.id.toLowerCase().startsWith(`${base}-`));
    if (loose) return loose.id;
  }

  return FALLBACK_LANGUAGE;
}


const KEY = "vr:prefs";
const EVENT = "vr:prefs-change";

export function readPrefs(): Prefs {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return { micDeviceId: null };

    const parsed = JSON.parse(raw) as Partial<Prefs>;
    return { micDeviceId: typeof parsed.micDeviceId === "string" ? parsed.micDeviceId : null };
  } catch {
    // 저장소가 막힌 환경(시크릿 모드 등)
    return { micDeviceId: null };
  }
}

/**
 * 실제로 전사에 쓸 언어.
 *
 * 계정에 골라 둔 것이 있으면 그것을, 없으면(**자동**) 브라우저 언어를 쓴다.
 * 녹음할 때 이 값이 세션 메타데이터로 실려 서버에 간다.
 */
export function resolveLanguage(account: { transcribe_language?: string | null } | null): string {
  const chosen = account?.transcribe_language;
  return LANGUAGES.some((l) => l.id === chosen) ? (chosen as string) : detectLanguage();
}

/**
 * 자동일 때 지금 무엇으로 정해지는지. 설정 화면이 "자동 — {이름}" 으로 보여주며,
 * 이름은 셸이 선택된 UI 언어의 `language.names.<id>` 로 렌더한다.
 */
export function autoLanguage(): string {
  return detectLanguage();
}

export function writePrefs(patch: Partial<Prefs>): Prefs {
  const next = { ...readPrefs(), ...patch };

  try {
    localStorage.setItem(KEY, JSON.stringify(next));
  } catch {
    // 저장 못 해도 이번 세션에는 적용된다
  }

  // 녹음 화면과 설정 화면이 동시에 떠 있을 수 있다. 한쪽에서 바꾸면 같이 움직인다.
  window.dispatchEvent(new CustomEvent(EVENT));
  return next;
}

/** 값이 바뀔 때 다시 읽게 한다. 해제 함수를 돌려준다. */
export function onPrefsChange(fn: () => void): () => void {
  window.addEventListener(EVENT, fn);
  // 다른 탭에서 바꾼 것도 따라간다
  window.addEventListener("storage", fn);

  return () => {
    window.removeEventListener(EVENT, fn);
    window.removeEventListener("storage", fn);
  };
}
