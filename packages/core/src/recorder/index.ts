export { Recorder } from "./recorder";
export { Emitter } from "./emitter";
export { pickMimeType, extensionFor, checkEnvironment } from "./mime";
export {
  classifyMediaError,
  detectPlatform,
  isPermissionCode,
  micErrorTitle,
  micRecoveryGuide,
  queryMicPermission,
  refinePermissionCode,
  watchMicPermission,
  PERMISSION_CODES,
} from "./permission";
export type {
  BrowserKind,
  EngineKind,
  GuideMessage,
  MicPermissionState,
  OsKind,
  PermissionErrorCode,
  Platform,
  RecoveryGuide,
} from "./permission";
export type {
  MicDevice,
  MicListResult,
  MicPermissionRequestResult,
  RecorderError,
  RecorderErrorCode,
  RecorderEvents,
  RecorderOptions,
  RecorderResult,
  RecorderState,
} from "./types";
