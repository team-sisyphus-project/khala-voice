/** 녹음 엔진의 공개 타입. */

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
  error: { code: RecorderErrorCode; message: string; cause?: unknown };
}

export type RecorderErrorCode =
  | "unsupported" // 브라우저가 MediaRecorder 를 지원하지 않음
  | "permission_denied" // 사용자가 마이크를 거부
  | "no_device" // 마이크가 없음
  | "insecure_context" // HTTPS 가 아님 — getUserMedia 가 막힌다
  | "interrupted" // OS/브라우저가 스트림을 끊음 (통화, 백그라운드 등)
  | "unknown";

export interface MicDevice {
  deviceId: string;
  label: string;
}
