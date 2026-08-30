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
import type { MicPermissionState, Platform, RecoveryGuide } from "./permission";
import type {
  MicListResult,
  MicPermissionRequestResult,
  RecorderErrorCode,
  RecorderEvents,
  RecorderOptions,
  RecorderState,
} from "./types";

const DEFAULT_MAX_SECONDS = 3 * 60 * 60; // 3시간
const DEFAULT_TIMESLICE = 1000;
const DEFAULT_FFT = 256;

/**
 * 녹음 엔진.
 *
 * ## 일시정지 정책 — 한 세션을 유지한다
 *
 * `MediaRecorder.pause()` / `resume()` 을 쓴다. 세션을 쪼개지 않는다.
 *
 * **출처: sisyphus** `assets/webapp/meeting-recorder.js` 3539~4110.
 *
 * sisyphus 데스크톱은 일시정지할 때마다 세션을 끊고 새로 만들었다.
 * 그러면 화자 번호 체계가 세션마다 독립적이라 "잠깐 멈췄다 이어서"가
 * 전사 단계에서 서로 다른 사람으로 갈라진다. 사용자 기대와도 다르다.
 *
 * ## 경과 시간
 *
 * 벽시계 차이에서 일시정지 누적을 뺀다. `MediaRecorder` 는 멈춰 있는 동안
 * 데이터를 만들지 않으므로, 빼지 않으면 표시 시간과 실제 오디오 길이가 어긋난다.
 *
 * ## 중단 감지
 *
 * 모바일에서 전화가 오거나 앱이 백그라운드로 가면 OS 가 트랙을 끊는다.
 * `track.onended` 로 감지해 **가진 데이터까지는 살린다.**
 * 이게 없으면 1시간 녹음이 통째로 사라진다.
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
  // TS 5.7+ 는 TypedArray 가 버퍼 타입으로 제네릭하다.
  // getFloatTimeDomainData 는 SharedArrayBuffer 백킹을 받지 않는다.
  #levels: Float32Array<ArrayBuffer> | null = null;

  #startedAtMs = 0;
  #startedAtUnix = 0;
  #pausedAtMs: number | null = null;
  #totalPausedMs = 0;
  #tickId: ReturnType<typeof setInterval> | null = null;
  #lastTickSecond = -1;

  // 안내 문구는 기기마다 다르다. 한 번만 읽어 둔다 — 도중에 바뀌지 않는다.
  #platform: Platform;
  #unwatchPermission: (() => void) | null = null;
  /** 구독으로 계속 갱신되는 최신 권한 상태. `start()` 가 동기로 읽는다. */
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

  /** 마지막으로 확인된 권한 상태. 확인 전이거나 알 수 없으면 `unknown`. */
  get permission(): MicPermissionState {
    return this.#permission;
  }

  /** 이 기기가 어떤 브라우저·OS 인지. 안내 문구를 고르는 근거. */
  get platform(): Platform {
    return this.#platform;
  }

  get state(): RecorderState {
    return this.#state;
  }

  get isActive(): boolean {
    return this.#state === "recording" || this.#state === "paused";
  }

  /** 일시정지를 뺀 경과 시간(초). */
  get elapsedSeconds(): number {
    if (!this.#startedAtMs) return 0;
    const pausedNow = this.#pausedAtMs ? Date.now() - this.#pausedAtMs : 0;
    return Math.floor((Date.now() - this.#startedAtMs - this.#totalPausedMs - pausedNow) / 1000);
  }

  get mimeType(): string | null {
    return this.#mimeType;
  }

  // ── 장치 ───────────────────────────────────────────────

  /** 지금 이 브라우저가 보고하는 마이크 권한 상태. Safari 는 `unknown`. */
  static probePermission(): Promise<MicPermissionState> {
    return queryMicPermission();
  }

  /**
   * 권한 상태 변화 구독. 구독 해제 함수를 돌려준다.
   *
   * 사용자가 브라우저 설정에서 차단을 푸는 순간 버튼이 살아나야 한다.
   * 이게 없으면 설정을 고쳐 놓고도 새로고침해야 한다는 걸 알 수 없다.
   */
  static watchPermission(onChange: (state: MicPermissionState) => void): () => void {
    return watchMicPermission(onChange);
  }

  /**
   * 마이크 목록.
   *
   * **권한을 받기 전에는 label 이 비어 있다.** 이건 브라우저의 지문 방지 정책이라
   * 우회할 수 없다.
   *
   * 라벨이 비었다고 무조건 "권한 주기" 버튼을 띄우면 안 된다. 이미 **차단**된
   * 상태에서도 라벨은 비어 있고, 그때 그 버튼은 눌러도 아무 일이 없다 —
   * 사용자는 버튼이 고장 났다고 읽는다. 그래서 권한 상태를 같이 돌려준다.
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
      // 일부 브라우저는 권한이 없으면 enumerateDevices 자체를 거부한다.
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
        label: d.label || `마이크 ${i + 1}`,
      })),
      // 차단된 상태에서는 물어봐야 소용이 없다
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
   * 권한만 받고 스트림은 바로 닫는다. 장치 라벨을 얻으려는 목적.
   *
   * 예전에는 `boolean` 만 돌려줘서 **왜 실패했는지가 통째로 사라졌다.**
   * 화면은 "권한 주기" 버튼을 다시 그리는 것 말고 할 수 있는 게 없었다.
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

  // ── 제어 ───────────────────────────────────────────────

  async start(): Promise<void> {
    if (this.isActive) return;

    const env = checkEnvironment();
    if (!env.ok) {
      this.#fail(env.code);
      return;
    }

    this.#setState("requesting");

    // 이미 차단이 굳었으면 굳이 물어보지 않는다.
    //
    // Chrome 은 이 상태에서 `getUserMedia` 를 **아무 UI 없이 즉시** 거부한다.
    // 그대로 두면 화면이 "마이크 준비 중" 을 한 번 깜빡이고 실패해서, 사용자는
    // 뭔가 시도되긴 했다고 착각한다. 먼저 걸러 원인을 그대로 말한다.
    //
    // 여기서 `await` 로 다시 물어보지 않는다. 구독으로 이미 알고 있는 값을 쓴다 —
    // `getUserMedia` 앞에 대기를 하나 더 두면 사용자 제스처와의 거리가 멀어져
    // 권한 창이 뜨지 않는 브라우저가 있다. 아직 모르면(`unknown`) 그냥 물어본다.
    const known = this.#permission;
    if (known === "denied") {
      this.#fail("permission_blocked", undefined, known);
      return;
    }

    try {
      this.#stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          // 모노 강제 — Google STT 의 화자분리는 단일 채널만 지원한다
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
          ...(this.#options.deviceId ? { deviceId: { exact: this.#options.deviceId } } : {}),
        },
      });
    } catch (error) {
      let code = classifyMediaError(error);

      // 거부된 뒤에야 "굳었는지" 를 알 수 있다. 요청 전 상태는 아직 `prompt` 다.
      let permission: MicPermissionState = known;
      if (isPermissionCode(code)) {
        permission = await queryMicPermission();
        code = refinePermissionCode(code, permission);
      }

      // 장치를 지정했는데 못 찾았다면 "마이크가 없다" 가 아니라
      // "골라 둔 마이크가 사라졌다" 다. 할 일이 다르다.
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

  /** 일시정지. 스트림은 살려둔다 — 재개 시 권한을 다시 묻지 않기 위해. */
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

  /** 녹음을 마치고 `complete` 이벤트로 결과를 준다. */
  stop(): void {
    if (!this.isActive || !this.#recorder) return;

    this.#setState("stopping");
    this.#stopTicking();
    this.#stopWaveform();

    // onstop 에서 blob 을 만든다. 여기서 만들면 마지막 청크가 빠진다.
    if (this.#recorder.state !== "inactive") {
      this.#recorder.stop();
    }
  }

  /** 저장하지 않고 버린다. */
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

  // ── 내부 ───────────────────────────────────────────────

  #setupRecorder(): void {
    this.#mimeType = pickMimeType();
    const options = this.#mimeType ? { mimeType: this.#mimeType } : {};
    this.#recorder = new MediaRecorder(this.#stream!, options);

    // 브라우저가 요청한 포맷을 거절하고 다른 걸 쓸 수 있다. 실제 값을 다시 읽는다.
    this.#mimeType = this.#recorder.mimeType || this.#mimeType;

    this.#recorder.ondataavailable = (event) => {
      if (event.data && event.data.size > 0) this.#chunks.push(event.data);
    };

    this.#recorder.onerror = (event) => {
      this.#fail("unknown", event, undefined, "녹음 중 오류가 발생했습니다");
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

    // 빈 녹음은 올려봐야 전사도 못 하고 크레딧만 쓴다
    if (blob.size === 0) {
      this.#fail("unknown", undefined, undefined, "녹음된 데이터가 없습니다");
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
      // 파형은 있으면 좋은 것이지 필수가 아니다. 실패해도 녹음은 계속한다.
      console.warn("[Recorder] 파형 분석기를 만들지 못했습니다:", error);
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

    // 250ms 마다 확인하고 초가 바뀔 때만 이벤트를 낸다.
    // 1초 간격 setInterval 은 드리프트가 쌓여 표시가 튄다.
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
   * OS 가 마이크를 뺏어가는 경우를 감지한다.
   * 전화 수신, 다른 앱의 마이크 점유, iOS 백그라운드 전환 등.
   */
  #watchInterruption(): void {
    for (const track of this.#stream?.getTracks() ?? []) {
      track.addEventListener("ended", () => {
        if (!this.isActive) return;

        this.events.emit("error", {
          code: "interrupted",
          message: "마이크 연결이 끊겼습니다. 지금까지 녹음된 내용을 저장합니다.",
          recovery: micRecoveryGuide("interrupted", this.#platform),
        });

        // 가진 데이터까지는 살린다
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
   * 실패를 알린다.
   *
   * 문구를 호출부에서 만들지 않는다. 같은 코드가 자리마다 다른 말을 하기
   * 시작하면 어느 안내가 맞는지 알 수 없게 된다 — 원인·할 일은 전부
   * `micRecoveryGuide` 한 곳에서 나온다.
   */
  #fail(
    code: RecorderErrorCode,
    cause?: unknown,
    permission?: MicPermissionState,
    override?: string,
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
