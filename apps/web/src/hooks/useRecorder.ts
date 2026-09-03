import { useCallback, useEffect, useRef, useState } from "react";
import { Recorder } from "@core/recorder";
import type {
  MicPermissionState,
  RecorderError,
  RecorderResult,
  RecorderState,
} from "@core/recorder";

export interface UseRecorderOptions {
  maxDurationSeconds?: number;
  deviceId?: string;
  /** Called with the result when recording finishes */
  onComplete?: (result: RecorderResult) => void;
  /** Keep the screen awake. On by default — guards against mobile background loss */
  keepScreenAwake?: boolean;
}

export interface UseRecorderResult {
  state: RecorderState;
  elapsedSeconds: number;
  remainingSeconds: number;
  /** 0–1. For the waveform animation */
  peak: number;
  /** The last failure. Carries the cause, what to do on this device, and whether retrying can work */
  error: RecorderError | null;
  /** Permission state as the browser reports it. Safari is always `unknown` */
  permission: MicPermissionState;
  /**
   * Whether recording can start on this device right now.
   *
   * **`false` only when definitely blocked.** Unknown means assume it can start
   * — declaring Safari blocked and locking the button would cut off users for
   * whom the permission prompt would actually appear.
   */
  canStart: boolean;
  /** Whether recording was ever auto-stopped because the mic dropped */
  wasInterrupted: boolean;
  isActive: boolean;
  start: () => void;
  togglePause: () => void;
  stop: () => void;
  cancel: () => void;
  /** Attach to the waveform canvas */
  canvasRef: React.RefObject<HTMLCanvasElement | null>;
}

/**
 * Connects the recording engine to React.
 *
 * The engine itself lives in `@core/recorder`; this hook is a thin adapter.
 * Don't put logic here — it would tie the logic back to the UI.
 *
 * ## The waveform is not React state
 *
 * Piping 60 frames per second through `setState` causes a re-render storm.
 * Draw directly onto the canvas, and hand React only `peak`, at low frequency.
 */
export function useRecorder(options: UseRecorderOptions = {}): UseRecorderResult {
  const { maxDurationSeconds = 3 * 60 * 60, deviceId, onComplete, keepScreenAwake = true } = options;

  const recorderRef = useRef<Recorder | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const wakeLockRef = useRef<WakeLockSentinel | null>(null);
  const onCompleteRef = useRef(onComplete);
  const lastPeakEmitRef = useRef(0);

  const [state, setState] = useState<RecorderState>("idle");
  const [elapsedSeconds, setElapsed] = useState(0);
  const [remainingSeconds, setRemaining] = useState(maxDurationSeconds);
  const [peak, setPeak] = useState(0);
  const [error, setError] = useState<RecorderError | null>(null);
  const [permission, setPermission] = useState<MicPermissionState>("unknown");
  const [wasInterrupted, setWasInterrupted] = useState(false);

  // Don't reattach listeners when the callback changes
  useEffect(() => {
    onCompleteRef.current = onComplete;
  }, [onComplete]);

  const releaseWakeLock = useCallback(async () => {
    await wakeLockRef.current?.release().catch(() => {});
    wakeLockRef.current = null;
  }, []);

  const acquireWakeLock = useCallback(async () => {
    if (!keepScreenAwake || !("wakeLock" in navigator)) return;

    try {
      wakeLockRef.current = await navigator.wakeLock.request("screen");
    } catch {
      // A WakeLock failure doesn't block recording. It just means the screen may turn off.
    }
  }, [keepScreenAwake]);

  // Coming back from the background, the WakeLock has been released. Reacquire it.
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible" && recorderRef.current?.isActive) {
        void acquireWakeLock();
      }
    };

    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [acquireWakeLock]);

  // The settings the engine was built with. Rebuild when they change.
  const optionsRef = useRef<{ deviceId?: string; maxDurationSeconds: number }>({
    deviceId,
    maxDurationSeconds,
  });

  // Read the wave color only when needed, not every frame, so it still tracks theme changes
  const waveColorRef = useRef<string>("");

  const waveColor = useCallback(() => {
    if (!waveColorRef.current) {
      const value = getComputedStyle(document.documentElement)
        // A design-system token. The old name (`--rec-recording`) only existed in
        // the LiveView CSS, so the React app always fell back to the hardcoded
        // color — it never followed the theme.
        .getPropertyValue("--mobile-danger")
        .trim();
      waveColorRef.current = value || "#e53935";
    }
    return waveColorRef.current;
  }, []);

  const drawWave = useCallback((levels: Float32Array) => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = window.devicePixelRatio || 1;
    const width = canvas.clientWidth;
    const height = canvas.clientHeight;

    if (canvas.width !== Math.round(width * dpr)) {
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }

    ctx.clearRect(0, 0, width, height);
    ctx.lineWidth = 2;
    ctx.lineJoin = "round";
    // Canvas can't use CSS variables directly. Read the computed value so the theme is honored.
    ctx.strokeStyle = waveColor();
    ctx.beginPath();

    const step = width / levels.length;
    for (let i = 0; i < levels.length; i++) {
      const y = height / 2 + (levels[i] ?? 0) * (height / 2) * 0.9;
      if (i === 0) ctx.moveTo(0, y);
      else ctx.lineTo(i * step, y);
    }

    ctx.stroke();
  }, [waveColor]);

  /**
   * The idle waveform — a flat line through the center.
   *
   * Even before recording, this area should read as **where the waveform will
   * live**. Left empty, the middle of the screen becomes a dead box, and
   * starting a recording produces no visible change.
   */
  const drawIdle = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const flat = new Float32Array(64);
    drawWave(flat);
  }, [drawWave]);

  useEffect(() => {
    if (state === "recording" || state === "paused") return;

    drawIdle();

    // When the width changes, the canvas size must be recomputed too
    const onResize = () => drawIdle();
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, [state, drawIdle]);

  /**
   * Keep the screen aware of the permission state at all times.
   *
   * The engine instance only exists once [Record] is pressed, so relying on it
   * alone means we can't know the mic is blocked **until the press**. The button
   * and status indicator must tell the truth before that.
   *
   * The moment the user unblocks the mic from browser settings in another tab
   * also lands here. When it flips to granted, clear any held error — a red
   * banner lingering after the fix reads as "still blocked".
   */
  useEffect(() => {
    let alive = true;

    void Recorder.probePermission().then((state) => {
      if (alive) setPermission(state);
    });

    const stop = Recorder.watchPermission((state) => {
      if (!alive) return;
      setPermission(state);
      if (state === "granted") setError(null);
    });

    return () => {
      alive = false;
      stop();
    };
  }, []);

  // When the theme changes, read the new color on the next frame
  useEffect(() => {
    const observer = new MutationObserver(() => {
      waveColorRef.current = "";
    });

    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    });

    return () => observer.disconnect();
  }, []);

  /**
   * Returns an engine built with the current settings.
   *
   * **Rebuild when the settings changed.** Previously the once-built instance
   * was returned forever, so while staying on the same screen **mic changes
   * were ignored from the second recording on** — the very failure that made
   * mic selection necessary (silently recording with the default device every
   * time) reproduced itself from take two onward.
   *
   * Never swap mid-recording — reopening the stream cuts at that point.
   */
  const ensureRecorder = useCallback((): Recorder => {
    const current = recorderRef.current;

    if (current) {
      const same =
        optionsRef.current.deviceId === deviceId &&
        optionsRef.current.maxDurationSeconds === maxDurationSeconds;

      if (same || current.isActive) return current;

      current.destroy();
      recorderRef.current = null;
    }

    optionsRef.current = { deviceId, maxDurationSeconds };

    const recorder = new Recorder({ maxDurationSeconds, deviceId });

    recorder.events.on("statechange", ({ state: next }) => setState(next));

    recorder.events.on("tick", ({ elapsedSeconds: e, remainingSeconds: r }) => {
      setElapsed(e);
      setRemaining(r);
    });

    recorder.events.on("waveform", ({ levels, peak: p }) => {
      drawWave(levels);

      // Promote peak to state only every 100ms. Every frame would cause a re-render storm.
      const now = performance.now();
      if (now - lastPeakEmitRef.current > 100) {
        lastPeakEmitRef.current = now;
        setPeak(p);
      }
    });

    recorder.events.on("error", (failure) => {
      setError(failure);
      if (failure.permission) setPermission(failure.permission);
      if (failure.code === "interrupted") setWasInterrupted(true);
    });

    recorder.events.on("permissionchange", ({ state }) => setPermission(state));

    recorder.events.on("complete", (result) => {
      void releaseWakeLock();
      setElapsed(0);
      setPeak(0);
      onCompleteRef.current?.(result);
    });

    recorderRef.current = recorder;
    return recorder;
  }, [maxDurationSeconds, deviceId, drawWave, releaseWakeLock]);

  const start = useCallback(() => {
    setError(null);
    setWasInterrupted(false);
    void acquireWakeLock();
    void ensureRecorder().start();
  }, [acquireWakeLock, ensureRecorder]);

  const togglePause = useCallback(() => recorderRef.current?.toggle(), []);
  const stop = useCallback(() => recorderRef.current?.stop(), []);

  const cancel = useCallback(() => {
    void releaseWakeLock();
    recorderRef.current?.cancel();
    setElapsed(0);
    setPeak(0);
  }, [releaseWakeLock]);

  // Warn before leaving mid-recording
  useEffect(() => {
    const handler = (event: BeforeUnloadEvent) => {
      if (recorderRef.current?.isActive) {
        event.preventDefault();
        event.returnValue = "";
      }
    };

    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
  }, []);

  useEffect(() => {
    return () => {
      void releaseWakeLock();
      recorderRef.current?.destroy();
      recorderRef.current = null;
    };
  }, [releaseWakeLock]);

  return {
    state,
    elapsedSeconds,
    remainingSeconds,
    peak,
    error,
    permission,
    // Block only what is definitely blocked. `unknown` (Safari) stays open.
    canStart: permission !== "denied",
    wasInterrupted,
    isActive: state === "recording" || state === "paused",
    start,
    togglePause,
    stop,
    cancel,
    canvasRef,
  };
}
