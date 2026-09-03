/**
 * Microphone — stays on **this device only**.
 *
 * The mic is a setting tied to a **place**, not a person. A meeting-room PC
 * always uses that room's USB mic; a phone always uses its built-in mic. Hang
 * it off the account so it follows across devices, and the mic picked in the
 * meeting room appears picked on the phone too.
 *
 * **The transcription language is not here.** That is tied to a person, so it
 * lives on the account (`CurrentAccount.transcribe_language`) and must follow
 * across devices.
 */

export interface Prefs {
  /** Microphone device ID. null means the browser/OS default device */
  micDeviceId: string | null;
}

/**
 * Transcription language list.
 *
 * Chosen mostly from what Google STT v2 (Chirp) supports together with speaker
 * diarization. Before adding a language not listed here, check transcription
 * quality first — diarization support varies per language.
 *
 * Display names don't live here — they must render in the selected UI language,
 * so the i18n catalog (`language.names.<id>`) is the single source of truth for
 * the strings. This holds only the STT codes (ids).
 */
export const LANGUAGES = [
  { id: "ko-KR" },
  { id: "en-US" },
  { id: "en-GB" },
  { id: "ja-JP" },
  // Chinese is `cmn-*`, not `zh-*` — that's how Google STT v2 codes it.
  // If this and the docs (`docs/04-pipeline.md`) disagree, transcription fails outright.
  { id: "cmn-Hans-CN" },
  { id: "cmn-Hant-TW" },
  { id: "es-ES" },
  { id: "fr-FR" },
  { id: "de-DE" },
  { id: "vi-VN" },
] as const;

/**
 * The value when even the browser language can't decide.
 *
 * **Must match** the server default (`transcription_worker.ex`) — a session
 * whose client failed to send a language must not get transcribed in a
 * different language server-side.
 */
export const FALLBACK_LANGUAGE = "en-US";

/**
 * Browser language → transcription language.
 *
 * Pinning a fixed value on first-time visitors means users in other locales
 * must switch by hand for every recording, and **one forgotten switch throws
 * away the entire meeting's transcript** (while still spending credits). So we
 * follow the browser's language.
 *
 * Prefer an exact region match; otherwise pick the representative for the same
 * language. If nothing matches, **English** — the default for a service
 * published as open source.
 */
function detectLanguage(): string {
  if (typeof navigator === "undefined") return FALLBACK_LANGUAGE;

  const wanted = navigator.languages?.length ? navigator.languages : [navigator.language];

  for (const raw of wanted) {
    if (!raw) continue;

    const tag = raw.toLowerCase();

    // A full-tag match, e.g. ko-KR
    const exact = LANGUAGES.find((l) => l.id.toLowerCase() === tag);
    if (exact) return exact.id;

    // zh-CN / zh-Hans need special-casing since the STT codes are cmn-*
    if (tag.startsWith("zh")) {
      return tag.includes("tw") || tag.includes("hant") || tag.includes("hk")
        ? "cmn-Hant-TW"
        : "cmn-Hans-CN";
    }

    // A language-only match, e.g. en → en-US
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
    // Storage-blocked environments (private browsing, etc.)
    return { micDeviceId: null };
  }
}

/**
 * The language actually used for transcription.
 *
 * The account's chosen language if set; otherwise (**auto**) the browser
 * language. When recording, this value rides along as session metadata to the
 * server.
 */
export function resolveLanguage(account: { transcribe_language?: string | null } | null): string {
  const chosen = account?.transcribe_language;
  return LANGUAGES.some((l) => l.id === chosen) ? (chosen as string) : detectLanguage();
}

/**
 * What "auto" resolves to right now. The settings screen shows it as
 * "Auto — {name}", where the shell renders the name via the selected UI
 * language's `language.names.<id>`.
 */
export function autoLanguage(): string {
  return detectLanguage();
}

export function writePrefs(patch: Partial<Prefs>): Prefs {
  const next = { ...readPrefs(), ...patch };

  try {
    localStorage.setItem(KEY, JSON.stringify(next));
  } catch {
    // Even if it can't be saved, it still applies for this session
  }

  // The recorder and settings screens can be up at the same time. A change on one side moves both.
  window.dispatchEvent(new CustomEvent(EVENT));
  return next;
}

/** Re-read when the value changes. Returns an unsubscribe function. */
export function onPrefsChange(fn: () => void): () => void {
  window.addEventListener(EVENT, fn);
  // Also follow changes made in other tabs
  window.addEventListener("storage", fn);

  return () => {
    window.removeEventListener(EVENT, fn);
    window.removeEventListener("storage", fn);
  };
}
