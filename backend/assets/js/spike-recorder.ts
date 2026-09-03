/**
 * Spike for verifying recording on real mobile devices.
 *
 * ## Why build this first
 *
 * This product's biggest unverified risk is **whether mobile browsers keep
 * recording in the background**. When the screen locks or the app goes to the
 * background, the OS can reclaim the microphone — iOS Safari is especially
 * restrictive.
 *
 * Discovering "you can't record a one-hour meeting on a phone" after building
 * everything is too late. Build a minimal UI and verify on real devices first.
 */

import {
  Recorder,
  checkEnvironment,
  detectPlatform,
  extensionFor,
  micErrorTitle,
  micRecoveryGuide,
} from "../../../packages/core/src/recorder";
import type { RecorderError } from "../../../packages/core/src/recorder";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const els = {
  env: $("env"),
  state: $("state"),
  timer: $("timer"),
  canvas: $<HTMLCanvasElement>("wave"),
  record: $<HTMLButtonElement>("record"),
  pause: $<HTMLButtonElement>("pause"),
  stop: $<HTMLButtonElement>("stop"),
  log: $("log"),
  result: $("result"),
  wakeLock: $<HTMLInputElement>("wakelock"),
};

let recorder: Recorder | null = null;
/** If the environment itself is unusable, the button must stay dead even after permission is granted. */
let environmentOk = true;
let wakeLock: WakeLockSentinel | null = null;
let visibilityEvents = 0;

function log(message: string, kind: "info" | "warn" | "error" | "ok" = "info") {
  const time = new Date().toLocaleTimeString("ko-KR", { hour12: false });
  const row = document.createElement("div");
  row.className = `log-row log-row--${kind}`;
  row.textContent = `${time}  ${message}`;
  els.log.prepend(row);
}

function fmt(seconds: number): string {
  const s = Math.max(0, seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(sec)}` : `${pad(m)}:${pad(sec)}`;
}

// ── Environment check ─────────────────────────────────────

function reportEnvironment() {
  const env = checkEnvironment();
  const rows: string[] = [];

  rows.push(`Secure context (HTTPS): ${window.isSecureContext ? "✅" : "❌"}`);
  rows.push(`MediaRecorder: ${typeof MediaRecorder !== "undefined" ? "✅" : "❌"}`);
  rows.push(`IndexedDB: ${typeof indexedDB !== "undefined" ? "✅" : "❌"}`);
  rows.push(`WakeLock: ${"wakeLock" in navigator ? "✅" : "— unsupported"}`);
  rows.push(`Permissions API: ${navigator.permissions ? "✅" : "— unsupported (Safari)"}`);

  // Visually confirm here that the permission guide identifies the device correctly.
  // This is where real-device testing catches "the guide points at the wrong menu".
  const platform = detectPlatform();
  rows.push(
    `Detected: ${platform.browser} / ${platform.engine} / ${platform.os}` +
      `${platform.webview ? " · in-app browser" : ""}${platform.standalone ? " · PWA" : ""}`,
  );
  rows.push(`UA: ${navigator.userAgent}`);

  els.env.innerHTML = rows.map((r) => `<div>${r}</div>`).join("");

  // Also record the current permission state. If it is blocked, pressing
  // [Start recording] is pointless — and the user should know before pressing.
  void Recorder.probePermission().then((state) => {
    els.env.innerHTML += `<div>Microphone permission: ${state}</div>`;
    if (state === "denied" && environmentOk) {
      els.record.disabled = true;
      describeError({
        code: "permission_blocked",
        message: micRecoveryGuide("permission_blocked").cause,
        recovery: micRecoveryGuide("permission_blocked"),
      });
    }
  });

  if (!env.ok) {
    environmentOk = false;
    log(env.message, "error");
    els.record.disabled = true;

    if (env.code === "insecure_context") {
      els.env.innerHTML +=
        `<div class="warn">⚠️ Not HTTPS, so the microphone cannot be used.` +
        ` To test on a phone, connect via an https address.</div>`;
    }
  }
}

// ── Screen wake lock ──────────────────────────────────────

async function acquireWakeLock() {
  if (!("wakeLock" in navigator)) return;

  try {
    wakeLock = await navigator.wakeLock.request("screen");
    log("WakeLock acquired — the screen will not turn off", "ok");

    wakeLock.addEventListener("release", () => {
      log("WakeLock released", "warn");
    });
  } catch (error) {
    log(`WakeLock failed: ${error instanceof Error ? error.message : error}`, "warn");
  }
}

async function releaseWakeLock() {
  await wakeLock?.release().catch(() => {});
  wakeLock = null;
}

// ── Background transition watch ───────────────────────────
// This log is the heart of this verification.
// It reveals whether recording survives the screen turning off or the app going to the background.

document.addEventListener("visibilitychange", () => {
  visibilityEvents++;
  const visible = document.visibilityState === "visible";
  log(`Screen state: ${visible ? "visible" : "hidden"} (event #${visibilityEvents})`, visible ? "info" : "warn");

  if (visible && recorder?.isActive) {
    log(`Recording state on return: ${recorder.state} · elapsed ${fmt(recorder.elapsedSeconds)}`, "ok");

    // iOS does not restore the WakeLock automatically on return from background
    if (els.wakeLock.checked && !wakeLock) void acquireWakeLock();
  }
});

window.addEventListener("pagehide", () => log("pagehide — the page is going away", "warn"));
window.addEventListener("freeze", () => log("freeze — the browser froze this tab", "error"));
window.addEventListener("resume", () => log("resume — the tab woke up", "ok"));

// ── Waveform ──────────────────────────────────────────────

function drawWave(levels: Float32Array) {
  const canvas = els.canvas;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;

  const dpr = window.devicePixelRatio || 1;
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;

  if (canvas.width !== width * dpr) {
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    ctx.scale(dpr, dpr);
  }

  ctx.clearRect(0, 0, width, height);
  ctx.lineWidth = 2;
  ctx.strokeStyle = "#f04452";
  ctx.beginPath();

  const step = width / levels.length;
  for (let i = 0; i < levels.length; i++) {
    const y = height / 2 + (levels[i] ?? 0) * (height / 2) * 0.9;
    if (i === 0) ctx.moveTo(0, y);
    else ctx.lineTo(i * step, y);
  }

  ctx.stroke();
}

// ── Recording controls ────────────────────────────────────

function bind(rec: Recorder) {
  rec.events.on("statechange", ({ state, previous }) => {
    els.state.textContent = state;
    els.state.dataset.state = state;
    log(`State: ${previous} → ${state}`);

    els.record.hidden = state === "recording" || state === "paused";
    els.pause.hidden = !(state === "recording" || state === "paused");
    els.stop.hidden = !(state === "recording" || state === "paused");
    els.pause.textContent = state === "paused" ? "Resume" : "Pause";
  });

  rec.events.on("tick", ({ elapsedSeconds, remainingSeconds }) => {
    els.timer.textContent = fmt(elapsedSeconds);

    // Log every minute so we can later confirm it kept running in the background
    if (elapsedSeconds > 0 && elapsedSeconds % 60 === 0) {
      log(`${elapsedSeconds / 60} min elapsed (time left ${fmt(remainingSeconds)})`, "ok");
    }
  });

  rec.events.on("waveform", ({ levels }) => drawWave(levels));

  rec.events.on("maxduration", ({ durationSeconds }) => {
    log(`Reached the maximum duration (${fmt(durationSeconds)}) — stopping automatically`, "warn");
  });

  rec.events.on("error", (failure) => {
    const { code, message, permission } = failure;
    log(
      `Error [${code}] ${message}${permission ? ` (permission: ${permission})` : ""}`,
      code === "interrupted" ? "warn" : "error",
    );
    describeError(failure);
  });

  rec.events.on("permissionchange", ({ state }) => {
    log(`Permission state changed: ${state}`, state === "denied" ? "error" : "ok");
    els.record.disabled = !environmentOk || state === "denied";
  });

  rec.events.on("complete", ({ blob, mimeType, durationSeconds, startedAtUnix }) => {
    void releaseWakeLock();

    const mb = (blob.size / 1024 / 1024).toFixed(2);
    const kbps = durationSeconds > 0 ? Math.round((blob.size * 8) / durationSeconds / 1000) : 0;
    const url = URL.createObjectURL(blob);

    log(`Recording complete — ${fmt(durationSeconds)} · ${mb}MB · ${kbps}kbps · ${mimeType}`, "ok");

    els.result.innerHTML = `
      <div class="result-card">
        <div class="result-row"><span>Duration</span><b>${fmt(durationSeconds)}</b></div>
        <div class="result-row"><span>Size</span><b>${mb} MB</b></div>
        <div class="result-row"><span>Bitrate</span><b>${kbps} kbps</b></div>
        <div class="result-row"><span>Format</span><b>${mimeType}</b></div>
        <div class="result-row"><span>Extension</span><b>.${extensionFor(mimeType)}</b></div>
        <div class="result-row"><span>Started</span><b>${new Date(startedAtUnix * 1000).toLocaleString("ko-KR")}</b></div>
        <div class="result-row"><span>Visibility changes</span><b>${visibilityEvents}</b></div>
        <audio controls src="${url}" style="width:100%; margin-top:12px"></audio>
      </div>
    `;
  });
}

/**
 * Prints the failure cause and what to do on this device, verbatim.
 *
 * The copy is not rewritten here — if the app and the spike suggest different
 * fixes, real-device findings can't be carried straight into the app. The guide
 * table lives in the engine, and only there.
 */
function describeError(failure: Pick<RecorderError, "code" | "recovery">) {
  const guide = failure.recovery ?? micRecoveryGuide(failure.code);

  log(`↳ ${micErrorTitle(failure.code)} — ${guide.cause}`, "warn");
  guide.steps.forEach((step, i) => log(`   ${i + 1}. ${step}`, "info"));

  if (!guide.retryable) log("   ↳ Pressing again will not bring up the permission prompt.", "error");
}

els.record.addEventListener("click", async () => {
  els.result.innerHTML = "";
  visibilityEvents = 0;

  recorder = new Recorder({ maxDurationSeconds: 3 * 60 * 60 });
  bind(recorder);

  if (els.wakeLock.checked) await acquireWakeLock();

  await recorder.start();
});

els.pause.addEventListener("click", () => recorder?.toggle());
els.stop.addEventListener("click", () => recorder?.stop());

// Warn on leaving while recording
window.addEventListener("beforeunload", (event) => {
  if (recorder?.isActive) {
    event.preventDefault();
    event.returnValue = "";
  }
});

reportEnvironment();
log("Spike ready. Press [Start recording], then try turning the screen off or switching apps.");
