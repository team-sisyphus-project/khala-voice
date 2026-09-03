/**
 * Per-browser audio format selection.
 *
 * Supported formats differ by browser.
 * - Chrome / Firefox / Edge → webm + opus
 * - Safari (incl. iOS)      → mp4 + aac
 *
 * Candidates are tried in order and the first supported one wins.
 * If all fail, return `null` and leave it to the browser default.
 */

import type { GuideMessage } from "./permission";

const CANDIDATES = [
  "audio/webm;codecs=opus",
  "audio/webm",
  "audio/mp4;codecs=mp4a.40.2", // Safari — AAC-LC
  "audio/mp4",
  "audio/ogg;codecs=opus",
] as const;

export function pickMimeType(): string | null {
  if (typeof MediaRecorder === "undefined") return null;

  for (const mime of CANDIDATES) {
    try {
      if (MediaRecorder.isTypeSupported(mime)) return mime;
    } catch {
      // Some browsers throw from isTypeSupported itself
    }
  }
  return null;
}

/** File extension from MIME. Must match the server's `VR.Storage.extension_for/1`. */
export function extensionFor(mimeType: string | null | undefined): string {
  if (!mimeType) return "bin";
  const base = mimeType.split(";")[0]?.trim() ?? "";

  switch (base) {
    case "audio/webm":
      return "webm";
    case "audio/ogg":
      return "ogg";
    case "audio/mp4":
      return "m4a";
    case "audio/mpeg":
      return "mp3";
    case "audio/wav":
    case "audio/x-wav":
      return "wav";
    default:
      return "bin";
  }
}

/**
 * Can this environment use getUserMedia?
 *
 * **Without HTTPS the microphone is unreachable.** localhost is the
 * exception. Real-device testing over `http://192.168.x.x` gets caught here.
 *
 * `message` is a locale-free key (`GuideMessage`) — the UI shell translates
 * the wording. core must stay framework- and i18n-agnostic (project rule 4).
 */
export function checkEnvironment():
  | { ok: true }
  | { ok: false; code: "unsupported" | "insecure_context"; message: GuideMessage } {
  if (typeof window === "undefined") {
    return { ok: false, code: "unsupported", message: { key: "env.notBrowser" } };
  }

  if (!window.isSecureContext) {
    return { ok: false, code: "insecure_context", message: { key: "env.insecure" } };
  }

  if (!navigator.mediaDevices?.getUserMedia) {
    return { ok: false, code: "unsupported", message: { key: "env.noGetUserMedia" } };
  }

  if (typeof MediaRecorder === "undefined") {
    return { ok: false, code: "unsupported", message: { key: "env.noMediaRecorder" } };
  }

  return { ok: true };
}
