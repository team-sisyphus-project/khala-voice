import { useCallback, useEffect, useRef, useState } from "react";
import { Recorder } from "@core/recorder";
import type { RecorderResult, RecorderState } from "@core/recorder";

export interface UseRecorderOptions {
  maxDurationSeconds?: number;
  deviceId?: string;
  /** 녹음이 끝나면 결과를 넘긴다 */
  onComplete?: (result: RecorderResult) => void;
  /** 화면 꺼짐 방지. 모바일 백그라운드 유실 대응이라 기본으로 켠다 */
  keepScreenAwake?: boolean;
}

export interface UseRecorderResult {
  state: RecorderState;
  elapsedSeconds: number;
  remainingSeconds: number;
  /** 0~1. 파형 애니메이션용 */
  peak: number;
  error: { code: string; message: string } | null;
  /** 마이크가 끊겨 자동 종료된 적이 있는가 */
  wasInterrupted: boolean;
  isActive: boolean;
  start: () => void;
  togglePause: () => void;
  stop: () => void;
  cancel: () => void;
  /** 파형 캔버스에 연결한다 */
  canvasRef: React.RefObject<HTMLCanvasElement | null>;
}

/**
 * 녹음 엔진을 React 에 연결한다.
 *
 * 엔진 자체는 `@core/recorder` 에 있고 이 훅은 얇은 어댑터다.
 * 로직을 여기에 넣지 않는다 — 그러면 다시 UI 에 묶인다.
 *
 * ## 파형은 상태로 다루지 않는다
 *
 * 초당 60프레임을 `setState` 로 흘리면 리렌더가 폭주한다.
 * 캔버스에 직접 그리고, React 에는 `peak` 만 낮은 빈도로 준다.
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
  const [error, setError] = useState<{ code: string; message: string } | null>(null);
  const [wasInterrupted, setWasInterrupted] = useState(false);

  // 콜백이 바뀌어도 리스너를 다시 붙이지 않는다
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
      // WakeLock 실패는 녹음을 막지 않는다. 화면이 꺼질 수 있다는 뜻일 뿐.
    }
  }, [keepScreenAwake]);

  // 백그라운드에서 돌아오면 WakeLock 이 풀려 있다. 다시 잡는다.
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible" && recorderRef.current?.isActive) {
        void acquireWakeLock();
      }
    };

    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [acquireWakeLock]);

  // 어떤 설정으로 만든 엔진인지. 설정이 바뀌면 다시 만든다.
  const optionsRef = useRef<{ deviceId?: string; maxDurationSeconds: number }>({
    deviceId,
    maxDurationSeconds,
  });

  // 테마가 바뀌어도 파형 색이 따라오도록 매 프레임이 아니라 필요할 때만 읽는다
  const waveColorRef = useRef<string>("");

  const waveColor = useCallback(() => {
    if (!waveColorRef.current) {
      const value = getComputedStyle(document.documentElement)
        // 디자인 시스템 토큰이다. 옛 이름(`--rec-recording`)은 LiveView 쪽 CSS 에만
        // 있어서 React 앱에서는 늘 폴백 색이 나갔다 — 테마를 따라가지 않았다.
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
    // 캔버스는 CSS 변수를 직접 못 쓴다. 계산된 값을 읽어와 테마를 따라가게 한다.
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
   * 쉬는 상태의 파형 — 가운데 평평한 선.
   *
   * 녹음 전에도 이 자리는 **파형이 설 자리**로 읽혀야 한다. 비워 두면 화면
   * 한가운데가 죽은 상자가 되고, 녹음을 시작해도 뭐가 달라졌는지 눈에 안 띈다.
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

    // 폭이 바뀌면 캔버스 크기도 다시 잡아야 한다
    const onResize = () => drawIdle();
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, [state, drawIdle]);

  // 테마가 바뀌면 다음 프레임에서 새 색을 읽는다
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
   * 지금 설정으로 만든 엔진을 돌려준다.
   *
   * **설정이 바뀌었으면 다시 만든다.** 예전에는 한 번 만든 인스턴스를 계속
   * 돌려줘서, 같은 화면에 머무는 동안 **두 번째 녹음부터 마이크 변경이 무시됐다**
   * — 마이크를 고를 수 있게 만든 이유(늘 기본 장치로만 녹음되는 조용한 실패)가
   * 2회차부터 그대로 재현됐다.
   *
   * 녹음 중에는 바꾸지 않는다 — 스트림을 다시 열면 그 지점이 잘린다.
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

      // peak 은 100ms 마다만 상태로 올린다. 매 프레임 올리면 리렌더가 폭주한다.
      const now = performance.now();
      if (now - lastPeakEmitRef.current > 100) {
        lastPeakEmitRef.current = now;
        setPeak(p);
      }
    });

    recorder.events.on("error", ({ code, message }) => {
      setError({ code, message });
      if (code === "interrupted") setWasInterrupted(true);
    });

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

  // 녹음 중 이탈 경고
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
    wasInterrupted,
    isActive: state === "recording" || state === "paused",
    start,
    togglePause,
    stop,
    cancel,
    canvasRef,
  };
}
