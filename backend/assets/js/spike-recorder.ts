/**
 * 모바일 실기기 녹음 검증용 스파이크.
 *
 * ## 왜 이걸 먼저 만드나
 *
 * 이 제품의 가장 큰 미검증 리스크는 **모바일 브라우저가 백그라운드에서
 * 녹음을 유지하는가**다. 화면이 잠기거나 앱이 뒤로 가면 OS 가 마이크를
 * 회수할 수 있고, iOS Safari 가 특히 제약이 크다.
 *
 * 기능을 다 만들고 나서 "1시간 회의를 폰으로 녹음할 수 없다"를 발견하면 늦다.
 * UI 를 최소로 만들어 실기기에서 먼저 확인한다.
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
/** 환경 자체가 안 되면 권한이 풀려도 버튼을 되살리면 안 된다. */
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

// ── 환경 점검 ─────────────────────────────────────────────

function reportEnvironment() {
  const env = checkEnvironment();
  const rows: string[] = [];

  rows.push(`보안 컨텍스트(HTTPS): ${window.isSecureContext ? "✅" : "❌"}`);
  rows.push(`MediaRecorder: ${typeof MediaRecorder !== "undefined" ? "✅" : "❌"}`);
  rows.push(`IndexedDB: ${typeof indexedDB !== "undefined" ? "✅" : "❌"}`);
  rows.push(`WakeLock: ${"wakeLock" in navigator ? "✅" : "— 미지원"}`);
  rows.push(`Permissions API: ${navigator.permissions ? "✅" : "— 미지원(Safari)"}`);

  // 권한 안내가 기기를 제대로 알아보는지 여기서 눈으로 확인한다.
  // 실기기 검증에서 "안내가 엉뚱한 메뉴를 가리킨다" 를 잡아내는 자리다.
  const platform = detectPlatform();
  rows.push(
    `판별: ${platform.browser} / ${platform.engine} / ${platform.os}` +
      `${platform.webview ? " · 인앱 브라우저" : ""}${platform.standalone ? " · PWA" : ""}`,
  );
  rows.push(`UA: ${navigator.userAgent}`);

  els.env.innerHTML = rows.map((r) => `<div>${r}</div>`).join("");

  // 지금 권한이 어떤 상태인지도 적어 둔다. 차단이면 [녹음 시작] 은 눌러야
  // 소용이 없고, 그 사실을 누르기 전에 알아야 한다.
  void Recorder.probePermission().then((state) => {
    els.env.innerHTML += `<div>마이크 권한: ${state}</div>`;
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
        `<div class="warn">⚠️ HTTPS 가 아니라 마이크를 쓸 수 없습니다.` +
        ` 폰에서 테스트하려면 https 주소로 접속해야 합니다.</div>`;
    }
  }
}

// ── 화면 꺼짐 방지 ────────────────────────────────────────

async function acquireWakeLock() {
  if (!("wakeLock" in navigator)) return;

  try {
    wakeLock = await navigator.wakeLock.request("screen");
    log("WakeLock 획득 — 화면이 꺼지지 않습니다", "ok");

    wakeLock.addEventListener("release", () => {
      log("WakeLock 해제됨", "warn");
    });
  } catch (error) {
    log(`WakeLock 실패: ${error instanceof Error ? error.message : error}`, "warn");
  }
}

async function releaseWakeLock() {
  await wakeLock?.release().catch(() => {});
  wakeLock = null;
}

// ── 백그라운드 전환 감시 ──────────────────────────────────
// 이 로그가 이번 검증의 핵심이다.
// 화면이 꺼지거나 앱이 뒤로 갔을 때 녹음이 살아있는지 여기서 드러난다.

document.addEventListener("visibilitychange", () => {
  visibilityEvents++;
  const visible = document.visibilityState === "visible";
  log(`화면 상태: ${visible ? "보임" : "숨김"} (${visibilityEvents}번째)`, visible ? "info" : "warn");

  if (visible && recorder?.isActive) {
    log(`복귀 시점 녹음 상태: ${recorder.state} · 경과 ${fmt(recorder.elapsedSeconds)}`, "ok");

    // iOS 는 백그라운드 복귀 시 WakeLock 을 자동으로 돌려주지 않는다
    if (els.wakeLock.checked && !wakeLock) void acquireWakeLock();
  }
});

window.addEventListener("pagehide", () => log("pagehide — 페이지가 내려갑니다", "warn"));
window.addEventListener("freeze", () => log("freeze — 브라우저가 탭을 얼렸습니다", "error"));
window.addEventListener("resume", () => log("resume — 탭이 깨어났습니다", "ok"));

// ── 파형 ──────────────────────────────────────────────────

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

// ── 녹음 제어 ─────────────────────────────────────────────

function bind(rec: Recorder) {
  rec.events.on("statechange", ({ state, previous }) => {
    els.state.textContent = state;
    els.state.dataset.state = state;
    log(`상태: ${previous} → ${state}`);

    els.record.hidden = state === "recording" || state === "paused";
    els.pause.hidden = !(state === "recording" || state === "paused");
    els.stop.hidden = !(state === "recording" || state === "paused");
    els.pause.textContent = state === "paused" ? "재개" : "일시정지";
  });

  rec.events.on("tick", ({ elapsedSeconds, remainingSeconds }) => {
    els.timer.textContent = fmt(elapsedSeconds);

    // 1분마다 로그를 남겨 백그라운드에서도 돌았는지 나중에 확인할 수 있게 한다
    if (elapsedSeconds > 0 && elapsedSeconds % 60 === 0) {
      log(`${elapsedSeconds / 60}분 경과 (남은 시간 ${fmt(remainingSeconds)})`, "ok");
    }
  });

  rec.events.on("waveform", ({ levels }) => drawWave(levels));

  rec.events.on("maxduration", ({ durationSeconds }) => {
    log(`최대 시간(${fmt(durationSeconds)}) 도달 — 자동 종료`, "warn");
  });

  rec.events.on("error", (failure) => {
    const { code, message, permission } = failure;
    log(
      `오류 [${code}] ${message}${permission ? ` (권한: ${permission})` : ""}`,
      code === "interrupted" ? "warn" : "error",
    );
    describeError(failure);
  });

  rec.events.on("permissionchange", ({ state }) => {
    log(`권한 상태 변경: ${state}`, state === "denied" ? "error" : "ok");
    els.record.disabled = !environmentOk || state === "denied";
  });

  rec.events.on("complete", ({ blob, mimeType, durationSeconds, startedAtUnix }) => {
    void releaseWakeLock();

    const mb = (blob.size / 1024 / 1024).toFixed(2);
    const kbps = durationSeconds > 0 ? Math.round((blob.size * 8) / durationSeconds / 1000) : 0;
    const url = URL.createObjectURL(blob);

    log(`녹음 완료 — ${fmt(durationSeconds)} · ${mb}MB · ${kbps}kbps · ${mimeType}`, "ok");

    els.result.innerHTML = `
      <div class="result-card">
        <div class="result-row"><span>길이</span><b>${fmt(durationSeconds)}</b></div>
        <div class="result-row"><span>크기</span><b>${mb} MB</b></div>
        <div class="result-row"><span>비트레이트</span><b>${kbps} kbps</b></div>
        <div class="result-row"><span>포맷</span><b>${mimeType}</b></div>
        <div class="result-row"><span>확장자</span><b>.${extensionFor(mimeType)}</b></div>
        <div class="result-row"><span>시작</span><b>${new Date(startedAtUnix * 1000).toLocaleString("ko-KR")}</b></div>
        <div class="result-row"><span>화면 전환</span><b>${visibilityEvents}회</b></div>
        <audio controls src="${url}" style="width:100%; margin-top:12px"></audio>
      </div>
    `;
  });
}

/**
 * 실패 원인과 이 기기에서 할 일을 그대로 찍는다.
 *
 * 문구를 여기서 다시 쓰지 않는다 — 앱과 스파이크가 서로 다른 해결책을 말하면
 * 실기기 검증 결과를 앱에 그대로 옮길 수 없다. 안내표는 엔진 한 곳에만 있다.
 */
function describeError(failure: Pick<RecorderError, "code" | "recovery">) {
  const guide = failure.recovery ?? micRecoveryGuide(failure.code);

  log(`↳ ${micErrorTitle(failure.code)} — ${guide.cause}`, "warn");
  guide.steps.forEach((step, i) => log(`   ${i + 1}. ${step}`, "info"));

  if (!guide.retryable) log("   ↳ 다시 눌러도 권한 창은 뜨지 않습니다.", "error");
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

// 녹음 중 이탈 경고
window.addEventListener("beforeunload", (event) => {
  if (recorder?.isActive) {
    event.preventDefault();
    event.returnValue = "";
  }
});

reportEnvironment();
log("스파이크 준비 완료. [녹음 시작] 을 누르고 화면을 끄거나 다른 앱으로 전환해 보세요.");
