import { Emitter } from "./emitter";
import { checkEnvironment, pickMimeType } from "./mime";
import {
  classifyMediaError,
  detectPlatform,
  isPermissionCode,
  micRecoveryGuide,
  queryMicPermission,
  refinePermissionCode,
  watchMicPermission,
} from "./permission";
import type { GuideMessage, MicPermissionState, Platform, RecoveryGuide } from "./permission";
import type {
  MicListResult,
  MicPermissionRequestResult,
  RecorderErrorCode,
  RecorderEvents,
  RecorderOptions,
  RecorderState,
} from "./types";

const DEFAULT_MAX_SECONDS = 3 * 60 * 60; // 3 hours
const DEFAULT_TIMESLICE = 1000;
const DEFAULT_FFT = 256;

/**
 * Recording engine.
 *
 * ## Pause policy — one session, kept alive
 *
 * Uses `MediaRecorder.pause()` / `resume()`. The session is never split.
 *
 * **Source: sisyphus** `assets/webapp/meeting-recorder.js` 3539~4110.
 *
 * sisyphus desktop tore down and recreated the session on every pause. With
 * speaker numbering independent per session, "pause briefly, then continue"
 * splits into different people at the transcription stage. It also defies
 * user expectations.
 *
 * ## Elapsed time
 *
 * Wall-clock delta minus accumulated pause time. `MediaRecorder` produces no
 * data while paused, so without the subtraction the displayed time drifts
 * from the actual audio length.
 *
 * ## Interruption detection
 *
 * On mobile, an incoming call or backgrounding makes the OS cut the track.
 * We detect it via `track.onended` and **salvage the data we have.**
 * Without this, an hour-long recording vanishes wholesale.
 */
export class Recorder {
  readonly events = new Emitter<RecorderEvents>();

  #state: RecorderState = "idle";
  #options: Required<Omit<RecorderOptions, "deviceId">> & { deviceId?: string };

  #stream: MediaStream | null = null;
  #recorder: MediaRecorder | null = null;
  #chunks: Blob[] = [];
  #mimeType: string | null = null;

  #audioContext: AudioContext | null = null;
  #analyser: AnalyserNode | null = null;
  #frameId: number | null = null;
  // In TS 5.7+ TypedArray is generic over its buffer type.
  // getFloatTimeDomainData does not accept SharedArrayBuffer backing.
  #levels: Float32Array<ArrayBuffer> | null = null;

  #startedAtMs = 0;
  #startedAtUnix = 0;
  #pausedAtMs: number | null = null;
  #totalPausedMs = 0;
  #tickId: ReturnType<typeof setInterval> | null = null;
  #lastTickSecond = -1;

  // Guidance wording differs per device. Read once — it does not change mid-run.
  #platform: Platform;
  #unwatchPermission: (() => void) | null = null;
  /** Latest permission state, kept fresh by the watch. `start()` reads it synchronously. */
  #permission: MicPermissionState = "unknown";

  constructor(options: RecorderOptions = {}) {
    this.#options = {
      maxDurationSeconds: options.maxDurationSeconds ?? DEFAULT_MAX_SECONDS,
      timesliceMs: options.timesliceMs ?? DEFAULT_TIMESLICE,
      fftSize: options.fftSize ?? DEFAULT_FFT,
      deviceId: options.deviceId,
    };

    this.#platform = detectPlatform();
    this.#unwatchPermission = watchMicPermission((state) => {
      this.#permission = state;
      this.events.emit("permissionchange", { state });
    });
  }

  /** Last observed permission state. `unknown` before any check or when unknowable. */
  get permission(): MicPermissionState {
    return this.#permission;
  }

  /** What browser/OS this device is. The basis for picking guidance wording. */
  get platform(): Platform {
    return this.#platform;
  }

  get state(): RecorderState {
    return this.#state;
  }

  get isActive(): boolean {
    return this.#state === "recording" || this.#state === "paused";
  }

  /** Elapsed time minus pauses (seconds). */
  get elapsedSeconds(): number {
    if (!this.#startedAtMs) return 0;
    const pausedNow = this.#pausedAtMs ? Date.now() - this.#pausedAtMs : 0;
    return Math.floor((Date.now() - this.#startedAtMs - this.#totalPausedMs - pausedNow) / 1000);
  }

  get mimeType(): string | null {
    return this.#mimeType;
  }

  // ── Devices ────────────────────────────────────────────

  /** The microphone permission state this browser reports right now. Safari gives `unknown`. */
  static probePermission(): Promise<MicPermissionState> {
    return queryMicPermission();
  }

  /**
   * Subscribes to permission state changes. Returns an unsubscribe function.
   *
   * The button must come alive the moment the user lifts the block in
   * browser settings. Without this, they fix the setting and still cannot
   * tell that a refresh is needed.
   */
  static watchPermission(onChange: (state: MicPermissionState) => void): () => void {
    return watchMicPermission(onChange);
  }

  /**
   * Microphone list.
   *
   * **Labels are empty until permission is granted.** That is the browser's
   * anti-fingerprinting policy and cannot be bypassed.
   *
   * Empty labels must not automatically raise a "grant permission" button.
   * Labels are also empty when already **blocked**, and then the button does
   * nothing when pressed — the user reads it as broken. So the permission
   * state is returned alongside.
   */
  static async listMicrophones(): Promise<MicListResult> {
    const platform = detectPlatform();
    const env = checkEnvironment();

    if (!env.ok) {
      return {
        devices: [],
        needsPermission: false,
        permission: "unknown",
        blocked: {
          code: env.code,
          message: env.message,
          recovery: micRecoveryGuide(env.code, platform),
        },
      };
    }

    const permission = await queryMicPermission();

    let inputs: MediaDeviceInfo[] = [];
    try {
      const all = await navigator.mediaDevices.enumerateDevices();
      inputs = all.filter((d) => d.kind === "audioinput");
    } catch (error) {
      // Some browsers reject enumerateDevices itself without permission.
      const code = classifyMediaError(error);
      return {
        devices: [],
        needsPermission: permission !== "denied",
        permission,
        blocked: {
          code,
          message: micRecoveryGuide(code, platform).cause,
          recovery: micRecoveryGuide(code, platform),
        },
      };
    }

    const labelsHidden = inputs.length > 0 && inputs.every((d) => !d.label);

    return {
      devices: inputs.map((d, i) => ({
        deviceId: d.deviceId,
        // The shell builds the fallback label from `index` — core produces no wording.
        label: d.label,
        index: i + 1,
      })),
      // Asking is pointless while blocked
      needsPermission: labelsHidden && permission !== "denied",
      permission,
      ...(permission === "denied"
        ? {
            blocked: {
              code: "permission_blocked" as const,
              message: micRecoveryGuide("permission_blocked", platform).cause,
              recovery: micRecoveryGuide("permission_blocked", platform),
            },
          }
        : {}),
    };
  }

  /**
   * Takes the permission and closes the stream immediately. The goal is
   * getting device labels.
   *
   * This used to return only a `boolean`, so **why it failed vanished
   * entirely.** All the UI could do was redraw the "grant permission"
   * button.
   */
  static async requestPermission(): Promise<MicPermissionRequestResult> {
    const platform = detectPlatform();
    const env = checkEnvironment();

    if (!env.ok) {
      return {
        granted: false,
        permission: "unknown",
        error: {
          code: env.code,
          message: env.message,
          recovery: micRecoveryGuide(env.code, platform),
        },
      };
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      stream.getTracks().forEach((t) => t.stop());
      return { granted: true, permission: "granted" };
    } catch (error) {
      const permission = await queryMicPermission();
      const code = refinePermissionCode(classifyMediaError(error), permission);
      const recovery = micRecoveryGuide(code, platform);

      return {
        granted: false,
        permission,
        error: { code, message: recovery.cause, permission, recovery, cause: error },
      };
    }
  }

  // ── Control ────────────────────────────────────────────

  async start(): Promise<void> {
    if (this.isActive) return;

    const env = checkEnvironment();
    if (!env.ok) {
      this.#fail(env.code);
      return;
    }

    this.#setState("requesting");

    // If the block has already hardened, do not bother asking.
    //
    // Chrome rejects `getUserMedia` here **immediately, with no UI at all.**
    // Left alone, the screen flashes "preparing microphone" once and fails,
    // and the user believes something was at least attempted. Filter first
    // and state the cause plainly.
    //
    // No re-querying with `await` here. Use the value the watch already
    // knows — one more wait before `getUserMedia` puts distance between it
    // and the user gesture, and some browsers then never show the prompt.
    // If still unknown (`unknown`), just ask.
    const known = this.#permission;
    if (known === "denied") {
      this.#fail("permission_blocked", undefined, known);
      return;
    }

    try {
      this.#stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          // Force mono — Google STT's speaker diarization supports single channel only
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
          ...(this.#options.deviceId ? { deviceId: { exact: this.#options.deviceId } } : {}),
        },
      });
    } catch (error) {
      let code = classifyMediaError(error);

      // Only after a denial can we tell whether it "hardened". Before the request the state is still `prompt`.
      let permission: MicPermissionState = known;
      if (isPermissionCode(code)) {
        permission = await queryMicPermission();
        code = refinePermissionCode(code, permission);
      }

      // If a device was specified and not found, that is not "no microphone" —
      // it is "the chosen microphone disappeared". The next step differs.
      if (code === "no_device" && this.#options.deviceId) code = "device_unavailable";

      this.#fail(code, error, permission);
      return;
    }

    this.#watchInterruption();
    this.#setupAnalyser();
    this.#setupRecorder();

    this.#chunks = [];
    this.#startedAtMs = Date.now();
    this.#startedAtUnix = Math.floor(this.#startedAtMs / 1000);
    this.#pausedAtMs = null;
    this.#totalPausedMs = 0;
    this.#lastTickSecond = -1;

    this.#recorder!.start(this.#options.timesliceMs);
    this.#setState("recording");
    this.#startTicking();
    this.#drawWaveform();
  }

  /** Pause. The stream stays alive — so resuming never re-asks for permission. */
  pause(): void {
    if (this.#state !== "recording" || !this.#recorder) return;
    if (this.#recorder.state !== "recording") return;

    this.#recorder.pause();
    this.#pausedAtMs = Date.now();
    this.#stopWaveform();
    this.#setState("paused");
  }

  resume(): void {
    if (this.#state !== "paused" || !this.#recorder) return;

    if (this.#pausedAtMs) {
      this.#totalPausedMs += Date.now() - this.#pausedAtMs;
      this.#pausedAtMs = null;
    }

    this.#recorder.resume();
    this.#setState("recording");
    this.#drawWaveform();
  }

  toggle(): void {
    if (this.#state === "recording") this.pause();
    else if (this.#state === "paused") this.resume();
  }

  /** Finishes recording and delivers the result via the `complete` event. */
  stop(): void {
    if (!this.isActive || !this.#recorder) return;

    this.#setState("stopping");
    this.#stopTicking();
    this.#stopWaveform();

    // The blob is built in onstop. Building it here would drop the last chunk.
    if (this.#recorder.state !== "inactive") {
      this.#recorder.stop();
    }
  }

  /** Discards without saving. */
  cancel(): void {
    if (this.#recorder && this.#recorder.state !== "inactive") {
      this.#recorder.onstop = null;
      this.#recorder.stop();
    }
    this.#chunks = [];
    this.#teardown();
    this.#setState("idle");
  }

  destroy(): void {
    this.cancel();
    this.#unwatchPermission?.();
    this.#unwatchPermission = null;
    this.events.removeAll();
  }

  // ── Internal ───────────────────────────────────────────

  #setupRecorder(): void {
    this.#mimeType = pickMimeType();
    const options = this.#mimeType ? { mimeType: this.#mimeType } : {};
    this.#recorder = new MediaRecorder(this.#stream!, options);

    // The browser may reject the requested format and use another. Re-read the actual value.
    this.#mimeType = this.#recorder.mimeType || this.#mimeType;

    this.#recorder.ondataavailable = (event) => {
      if (event.data && event.data.size > 0) this.#chunks.push(event.data);
    };

    this.#recorder.onerror = (event) => {
      this.#fail("unknown", event, undefined, { key: "msg.recordError" });
    };

    this.#recorder.onstop = () => this.#finish();
  }

  #finish(): void {
    const mimeType = this.#mimeType ?? "audio/webm";
    const blob = new Blob(this.#chunks, { type: mimeType });
    const durationSeconds = this.elapsedSeconds;
    const startedAtUnix = this.#startedAtUnix;

    this.#chunks = [];
    this.#teardown();
    this.#setState("idle");

    // An empty recording cannot be transcribed and only burns credits
    if (blob.size === 0) {
      this.#fail("unknown", undefined, undefined, { key: "msg.emptyRecording" });
      return;
    }

    this.events.emit("complete", { blob, mimeType, durationSeconds, startedAtUnix });
  }

  #setupAnalyser(): void {
    try {
      const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
      this.#audioContext = new Ctx();
      this.#analyser = this.#audioContext.createAnalyser();
      this.#analyser.fftSize = this.#options.fftSize;
      this.#analyser.smoothingTimeConstant = 0.75;
      this.#audioContext.createMediaStreamSource(this.#stream!).connect(this.#analyser);
      this.#levels = new Float32Array(this.#analyser.frequencyBinCount);
    } catch (error) {
      // The waveform is nice to have, not required. Recording continues even if this fails.
      console.warn("[Recorder] could not create the waveform analyser:", error);
    }
  }

  #drawWaveform(): void {
    if (!this.#analyser || !this.#levels) return;

    const tick = () => {
      if (this.#state !== "recording" || !this.#analyser || !this.#levels) return;

      this.#analyser.getFloatTimeDomainData(this.#levels);

      let peak = 0;
      for (let i = 0; i < this.#levels.length; i++) {
        const value = Math.abs(this.#levels[i] ?? 0);
        if (value > peak) peak = value;
      }

      this.events.emit("waveform", { levels: this.#levels, peak });
      this.#frameId = requestAnimationFrame(tick);
    };

    this.#frameId = requestAnimationFrame(tick);
  }

  #stopWaveform(): void {
    if (this.#frameId !== null) {
      cancelAnimationFrame(this.#frameId);
      this.#frameId = null;
    }
  }

  #startTicking(): void {
    this.#stopTicking();

    // Check every 250ms and emit only when the second changes.
    // A 1-second setInterval accumulates drift and makes the display jump.
    this.#tickId = setInterval(() => {
      if (this.#state !== "recording") return;

      const elapsed = this.elapsedSeconds;
      if (elapsed === this.#lastTickSecond) return;
      this.#lastTickSecond = elapsed;

      const remaining = this.#options.maxDurationSeconds - elapsed;
      this.events.emit("tick", { elapsedSeconds: elapsed, remainingSeconds: remaining });

      if (remaining <= 0) {
        this.events.emit("maxduration", { durationSeconds: elapsed });
        this.stop();
      }
    }, 250);
  }

  #stopTicking(): void {
    if (this.#tickId !== null) {
      clearInterval(this.#tickId);
      this.#tickId = null;
    }
  }

  /**
   * Detects the OS taking the microphone away.
   * Incoming calls, another app seizing the mic, iOS backgrounding, etc.
   */
  #watchInterruption(): void {
    for (const track of this.#stream?.getTracks() ?? []) {
      track.addEventListener("ended", () => {
        if (!this.isActive) return;

        this.events.emit("error", {
          code: "interrupted",
          message: { key: "msg.interrupted" },
          recovery: micRecoveryGuide("interrupted", this.#platform),
        });

        // Salvage the data we have
        this.stop();
      });
    }
  }

  #teardown(): void {
    this.#stopTicking();
    this.#stopWaveform();

    this.#stream?.getTracks().forEach((track) => track.stop());
    this.#stream = null;

    this.#recorder = null;
    this.#analyser = null;
    this.#levels = null;

    void this.#audioContext?.close().catch(() => {});
    this.#audioContext = null;

    this.#startedAtMs = 0;
    this.#pausedAtMs = null;
    this.#totalPausedMs = 0;
  }

  #setState(next: RecorderState): void {
    if (this.#state === next) return;
    const previous = this.#state;
    this.#state = next;
    this.events.emit("statechange", { state: next, previous });
  }

  /**
   * Reports a failure.
   *
   * Wording is never built at the call site. Once the same code starts
   * saying different things in different places, nobody knows which guidance
   * is right — cause and steps all come from one place, `micRecoveryGuide`.
   */
  #fail(
    code: RecorderErrorCode,
    cause?: unknown,
    permission?: MicPermissionState,
    override?: GuideMessage,
  ): void {
    const recovery: RecoveryGuide = micRecoveryGuide(code, this.#platform);

    this.#teardown();
    this.#setState("error");
    this.events.emit("error", {
      code,
      message: override ?? recovery.cause,
      permission,
      recovery,
      cause,
    });
  }
}
