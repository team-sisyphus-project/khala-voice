/** Public types of the recording engine. */

import type { GuideMessage, MicPermissionState, RecoveryGuide } from "./permission";

export type RecorderState =
  | "idle"
  | "requesting" // requesting microphone permission
  | "recording"
  | "paused"
  | "stopping" // waiting for the final data after stop()
  | "error";

export interface RecorderOptions {
  /** Microphone device ID. Default device if empty */
  deviceId?: string;
  /** Maximum recording time (seconds). Default 3 hours */
  maxDurationSeconds?: number;
  /** Chunk collection interval (ms). Default 1000 */
  timesliceMs?: number;
  /** Waveform analysis resolution. Default 256 */
  fftSize?: number;
}

export interface RecorderResult {
  blob: Blob;
  mimeType: string;
  /** Actual recorded length minus paused time (seconds) */
  durationSeconds: number;
  startedAtUnix: number;
}

/**
 * One recording failure.
 *
 * A single `message` is not enough. The UI must render the **cause**, the
 * **steps to take**, and **whether pressing again helps** differently —
 * showing [Retry] on a hardened block leaves the user hammering the same
 * button.
 */
export interface RecorderError {
  code: RecorderErrorCode;
  /** One-line cause. Notification banner body. Locale-free key — the UI shell translates it with `t()` */
  message: GuideMessage;
  /** For permission-family errors, the state the browser reported. Safari gives `unknown` */
  permission?: MicPermissionState;
  /** What to do on this device */
  recovery?: RecoveryGuide;
  cause?: unknown;
}

export interface RecorderEvents {
  statechange: { state: RecorderState; previous: RecorderState };
  /** Updated every second. For the UI timer */
  tick: { elapsedSeconds: number; remainingSeconds: number };
  /** Waveform frame. At requestAnimationFrame cadence */
  waveform: { levels: Float32Array<ArrayBuffer>; peak: number };
  /** Recording finished. Data to hand to the upload queue */
  complete: RecorderResult;
  /** Auto-stopped after hitting the maximum duration */
  maxduration: { durationSeconds: number };
  /** Microphone permission state changed. Signal to redraw buttons/indicators */
  permissionchange: { state: MicPermissionState };
  error: RecorderError;
}

/**
 * Why recording was blocked.
 *
 * The permission family splits four ways because **the user's next step is
 * different in all four**. See `classifyMediaError` in `permission.ts` for
 * the details.
 */
export type RecorderErrorCode =
  | "unsupported" // browser lacks MediaRecorder / getUserMedia
  | "insecure_context" // not HTTPS — getUserMedia is blocked
  | "permission_denied" // denied; unknown whether asking again works (mostly Safari)
  | "permission_blocked" // hardened by a site-level block — browser settings must be opened
  | "permission_dismissed" // prompt dismissed — pressing again shows it again
  | "system_denied" // the browser itself is blocked in OS privacy settings
  | "embed_blocked" // blocked by iframe / in-app browser policy
  | "no_device" // no microphone
  | "device_unavailable" // the chosen microphone disappeared (OverconstrainedError)
  | "device_busy" // device exists but another app holds it (NotReadableError)
  | "interrupted" // OS/browser cut the stream (call, backgrounding, etc.)
  | "unknown";

export interface MicDevice {
  deviceId: string;
  /**
   * Device name from the browser. **Empty until permission is granted**
   * (anti-fingerprinting). The fallback label ("Microphone N") is built by
   * the UI shell from `index` — core produces no locale wording.
   */
  label: string;
  /** 1-based ordinal. The shell's basis for "Microphone N" when the label is empty. */
  index: number;
}

/** Result of listing microphones. */
export interface MicListResult {
  devices: MicDevice[];
  /**
   * Does seeing the labels require asking for permission?
   *
   * **`false` when blocked.** Showing a request button is pointless when the
   * prompt cannot appear — that case is split off via
   * `permission === "denied"` with different guidance.
   */
  needsPermission: boolean;
  permission: MicPermissionState;
  /** Why even the list could not be read. Not HTTPS, unsupported, etc. `message` is a locale-free key */
  blocked?: { code: RecorderErrorCode; message: GuideMessage; recovery: RecoveryGuide };
}

/** Result of a permission-only request. */
export interface MicPermissionRequestResult {
  granted: boolean;
  permission: MicPermissionState;
  /** Only on failure */
  error?: RecorderError;
}
