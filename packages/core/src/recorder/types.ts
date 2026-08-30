/** 녹음 엔진의 공개 타입. */

import type { MicPermissionState, RecoveryGuide } from "./permission";

export type RecorderState =
  | "idle"
  | "requesting" // 마이크 권한 요청 중
  | "recording"
  | "paused"
  | "stopping" // stop() 호출 후 최종 데이터 대기
  | "error";

export interface RecorderOptions {
  /** 마이크 장치 ID. 비우면 기본 장치 */
  deviceId?: string;
  /** 최대 녹음 시간(초). 기본 3시간 */
  maxDurationSeconds?: number;
  /** 청크 수집 주기(ms). 기본 1000 */
  timesliceMs?: number;
  /** 파형 분석 해상도. 기본 256 */
  fftSize?: number;
}

export interface RecorderResult {
  blob: Blob;
  mimeType: string;
  /** 일시정지 시간을 뺀 실제 녹음 길이(초) */
  durationSeconds: number;
  startedAtUnix: number;
}

/**
 * 녹음 실패 한 건.
 *
 * `message` 하나로는 부족하다. 화면은 **원인**과 **할 일**과 **다시 눌러도
 * 되는가**를 각각 다르게 그려야 한다 — 굳어버린 차단에서 [다시 시도] 를
 * 띄우면 사용자는 같은 버튼만 반복해서 누른다.
 */
export interface RecorderError {
  code: RecorderErrorCode;
  /** 한 줄 원인. 알림 띠 본문 */
  message: string;
  /** 권한 계열일 때 브라우저가 보고한 상태. Safari 는 `unknown` */
  permission?: MicPermissionState;
  /** 이 기기에서 할 일 */
  recovery?: RecoveryGuide;
  cause?: unknown;
}

export interface RecorderEvents {
  statechange: { state: RecorderState; previous: RecorderState };
  /** 매 초 갱신. UI 타이머용 */
  tick: { elapsedSeconds: number; remainingSeconds: number };
  /** 파형 프레임. requestAnimationFrame 주기 */
  waveform: { levels: Float32Array<ArrayBuffer>; peak: number };
  /** 녹음 완료. 업로드 큐로 넘길 데이터 */
  complete: RecorderResult;
  /** 최대 시간 도달으로 자동 종료됨 */
  maxduration: { durationSeconds: number };
  /** 마이크 권한 상태가 바뀜. 버튼·상태 표시기를 다시 그리라는 신호 */
  permissionchange: { state: MicPermissionState };
  error: RecorderError;
}

/**
 * 녹음이 막힌 이유.
 *
 * 권한 계열이 넷으로 갈라져 있는 것은 **사용자가 할 일이 넷 다 다르기 때문**이다.
 * 자세한 사정은 `permission.ts` 의 `classifyMediaError` 참고.
 */
export type RecorderErrorCode =
  | "unsupported" // 브라우저가 MediaRecorder / getUserMedia 를 지원하지 않음
  | "insecure_context" // HTTPS 가 아님 — getUserMedia 가 막힌다
  | "permission_denied" // 거부됨. 다시 물어볼 수 있는지는 알 수 없음 (주로 Safari)
  | "permission_blocked" // 사이트 차단으로 굳음 — 브라우저 설정을 열어야 한다
  | "permission_dismissed" // 권한 창을 그냥 닫음 — 다시 누르면 또 뜬다
  | "system_denied" // OS 개인정보 설정에서 브라우저 자체가 차단됨
  | "embed_blocked" // iframe / 인앱 브라우저 정책으로 막힘
  | "no_device" // 마이크가 없음
  | "device_unavailable" // 지정한 마이크가 사라짐 (OverconstrainedError)
  | "device_busy" // 장치는 있으나 다른 앱이 점유 중 (NotReadableError)
  | "interrupted" // OS/브라우저가 스트림을 끊음 (통화, 백그라운드 등)
  | "unknown";

export interface MicDevice {
  deviceId: string;
  label: string;
}

/** 마이크 목록 조회 결과. */
export interface MicListResult {
  devices: MicDevice[];
  /**
   * 라벨을 보려면 권한이 필요한 상태인가.
   *
   * **차단된 상태에서는 `false` 다.** 권한을 달라고 버튼을 띄워봐야 창이 뜨지
   * 않는다 — 그 경우는 `permission === "denied"` 로 갈라 안내를 바꾼다.
   */
  needsPermission: boolean;
  permission: MicPermissionState;
  /** 목록조차 못 읽은 이유. HTTPS 아님 · 미지원 등 */
  blocked?: { code: RecorderErrorCode; message: string; recovery: RecoveryGuide };
}

/** 권한만 받아 보는 요청의 결과. */
export interface MicPermissionRequestResult {
  granted: boolean;
  permission: MicPermissionState;
  /** 실패했을 때만 */
  error?: RecorderError;
}
