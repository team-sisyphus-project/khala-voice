/**
 * 브라우저별 오디오 포맷 선택.
 *
 * 브라우저마다 지원 포맷이 다르다.
 * - Chrome / Firefox / Edge → webm + opus
 * - Safari (iOS 포함)       → mp4 + aac
 *
 * 순서대로 시도해 처음 지원되는 것을 쓴다.
 * 전부 실패하면 `null` 을 주고 브라우저 기본값에 맡긴다.
 */

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
      // isTypeSupported 자체가 던지는 브라우저가 있다
    }
  }
  return null;
}

/** MIME 에서 파일 확장자. 서버의 `VR.Storage.extension_for/1` 과 맞춰야 한다. */
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
 * getUserMedia 를 쓸 수 있는 환경인가.
 *
 * **HTTPS 가 아니면 마이크에 접근할 수 없다.** localhost 는 예외다.
 * 실기기 테스트에서 `http://192.168.x.x` 로 붙으면 여기서 걸린다.
 */
export function checkEnvironment(): { ok: true } | { ok: false; code: "unsupported" | "insecure_context"; message: string } {
  if (typeof window === "undefined") {
    return { ok: false, code: "unsupported", message: "브라우저 환경이 아닙니다" };
  }

  if (!window.isSecureContext) {
    return {
      ok: false,
      code: "insecure_context",
      message:
        "HTTPS 가 아니면 마이크를 쓸 수 없습니다. localhost 이거나 https 주소로 접속해야 합니다.",
    };
  }

  if (!navigator.mediaDevices?.getUserMedia) {
    return { ok: false, code: "unsupported", message: "이 브라우저는 마이크 녹음을 지원하지 않습니다" };
  }

  if (typeof MediaRecorder === "undefined") {
    return { ok: false, code: "unsupported", message: "이 브라우저는 MediaRecorder 를 지원하지 않습니다" };
  }

  return { ok: true };
}
