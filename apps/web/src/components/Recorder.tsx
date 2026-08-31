import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import i18n from "@/i18n";
import { useRecorder } from "@/hooks/useRecorder";
import { formatDuration } from "@/lib/format";
import { api, uploader } from "@/lib/api";
import { Notice } from "./ui";
import { Button, Icon } from "@/ui";
import { RecordingPrefsSheet } from "./RecordingPrefsSheet";
import { usePrefs } from "@/hooks/usePrefs";
import { useAccount } from "@/hooks/useAccount";
import { languageLabel, resolveLanguage } from "@/lib/prefs";
import { micErrorTitle, micRecoveryGuide } from "@core/recorder";
import type {
  MicPermissionState,
  RecorderError,
  RecorderResult,
  RecorderState,
} from "@core/recorder";
import type { Meeting } from "@core/api";

/**
 * 녹음 컨트롤.
 *
 * ## 유실 방지 순서
 *
 *     1. 녹음 시작 전에 세션을 먼저 만든다
 *     2. 녹음 종료 → Blob
 *     3. IndexedDB 저장 (Uploader.enqueue)
 *     4. presign → S3 PUT → 서버 등록
 *
 * 1번을 먼저 하는 이유: 녹음이 끝난 뒤에 세션을 만들려다 네트워크가 끊기면
 * 어디에 붙일지 모르는 Blob 이 남는다. 미리 만들어 두면 오프라인에서도
 * 큐에 넣을 대상이 정해져 있다.
 */
export function RecorderPanel({
  meeting,
  onSessionCreated,
}: {
  meeting: Meeting;
  onSessionCreated: () => void;
}) {
  const { t } = useTranslation();
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [preparing, setPreparing] = useState(false);
  const [prepareError, setPrepareError] = useState<string | null>(null);
  const [queue, setQueue] = useState({ pending: 0, failed: 0 });
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);
  const [picking, setPicking] = useState(false);

  /**
   * 마이크는 **기기에**, 전사 언어는 **계정에** 있다.
   *
   * 마이크는 자리에 딸린 설정이라(회의실 PC 는 늘 그 방의 마이크) 기기에 남고,
   * 언어는 사람에 딸린 설정이라 기기를 바꿔도 따라와야 한다.
   */
  const [prefs, setPrefs] = usePrefs();
  const { account, setAccount } = useAccount();
  const language = resolveLanguage(account);

  const canRecord = meeting.status === "active" && meeting.role !== "viewer";

  const discardSession = useCallback((id: string | null) => {
    if (!id) return;
    // 실패해도 무시한다 — 서버에 빈 세션이 하나 남을 뿐이고, 사용자를 막을 이유가 없다
    void api.deleteSession(id).catch(() => {});
  }, []);

  const recorder = useRecorder({
    deviceId: prefs.micDeviceId ?? undefined,
    onComplete: (result: RecorderResult) => {
      if (!sessionId) return;

      void uploader.enqueue({
        id: sessionId,
        blob: result.blob,
        mimeType: result.mimeType,
        durationSeconds: result.durationSeconds,
        meetingId: meeting.id,
        startedAtUnix: result.startedAtUnix,
      });

      setSessionId(null);
      onSessionCreated();
    },
  });

  // 녹음 시작에 실패하면 미리 만들어 둔 세션이 고아로 남는다.
  // 마이크 거부·미지원처럼 데이터가 생길 수 없는 오류일 때 지운다.
  useEffect(() => {
    if (!recorder.error || !sessionId) return;
    if (recorder.error.code === "interrupted") return; // 이건 데이터가 있다

    discardSession(sessionId);
    setSessionId(null);
  }, [recorder.error, sessionId, discardSession]);

  /**
   * 골라 둔 마이크가 사라졌을 때 기본 장치로 되돌린다.
   *
   * 이 상태는 스스로 낫지 않는다 — 저장된 `micDeviceId` 가 계속 없는 장치를
   * 가리켜서 [녹음] 을 몇 번을 눌러도 같은 자리에서 실패한다. 되돌릴 길을
   * 화면에 두지 않으면 사용자는 녹음 설정 어딘가에 원인이 있다는 걸 모른다.
   */
  const fallbackToDefaultMic = useCallback(() => {
    setPrefs({ micDeviceId: null });
  }, [setPrefs]);

  useEffect(() => {
    uploader.start();

    const offQueue = uploader.on("queuechange", setQueue);
    const offProgress = uploader.on("progress", ({ done, total }) => setProgress({ done, total }));
    const offUploaded = uploader.on("uploaded", () => {
      setProgress(null);
      onSessionCreated();
    });
    const offFailed = uploader.on("failed", () => setProgress(null));

    return () => {
      offQueue();
      offProgress();
      offUploaded();
      offFailed();
    };
  }, [onSessionCreated]);

  async function handleStart() {
    setPrepareError(null);
    setPreparing(true);

    try {
      // 녹음을 시작하기 전에 세션을 확보한다
      const session = await api.createSession(meeting.id, {
        started_at_unix: Math.floor(Date.now() / 1000),
        // 전사는 언어를 알아야 한다. 서버 기본값(ko-KR)에 기대면 다른 언어 회의가
        // 통째로 잘못 전사되고 크레딧만 나간다.
        metadata: { language },
      });

      setSessionId(session.id);
      recorder.start();
    } catch (error) {
      setPrepareError(error instanceof Error ? error.message : t("recorder.startError"));
    } finally {
      setPreparing(false);
    }
  }

  function handleCancel() {
    recorder.cancel();
    discardSession(sessionId);
    setSessionId(null);
    onSessionCreated();
  }

  const showCountdown = recorder.isActive && recorder.remainingSeconds < 10 * 60;

  return (
    <div className="vr-recorder-panel">
      {!canRecord && (
        <Notice kind="info" icon="info" className="mb-4">
          {meeting.role === "viewer"
            ? t("recorder.viewerOnly")
            : t("recorder.completedRevert")}
        </Notice>
      )}

      {recorder.error && (
        <MicTrouble
          error={recorder.error}
          onRetry={handleStart}
          onUseDefaultMic={prefs.micDeviceId ? fallbackToDefaultMic : undefined}
        />
      )}

      {/*
        오류가 아직 없어도 **누르기 전에** 말해야 하는 것이 있다. 권한이 이미
        차단된 기기에서 [녹음] 은 눌러봐야 아무 창도 뜨지 않고 실패한다.
      */}
      {!recorder.error && !recorder.canStart && canRecord && (
        <MicTrouble error={blockedBeforeStart(recorder.permission)} />
      )}

      {prepareError && (
        <Notice kind="error" icon="error" className="mb-4">{prepareError}</Notice>
      )}

      {/* 중단은 `error` 로도 들어와 MicTrouble 이 절차까지 보여준다.
          여기는 그게 없을 때만 서는 자리다 — 같은 말을 두 번 하지 않는다. */}
      {recorder.wasInterrupted && !recorder.error && (
        <Notice kind="warn" icon="phone_disabled" title={t("recorder.interruptedTitle")} className="mb-4">
          {t("recorder.interruptedBody")}
        </Notice>
      )}

      {showCountdown && (
        <Notice kind="warn" icon="timer" className="mb-4">
          {t("recorder.countdown", { time: formatDuration(recorder.remainingSeconds) })}
        </Notice>
      )}

      <div className="vr-recorder">
        <div className="vr-recorder__head" style={{ textAlign: "center" }}>
          <div
            className="vr-recorder__timer"
            style={
              recorder.state === "recording" ? { color: "var(--mobile-danger)" } : undefined
            }
          >
            {formatDuration(recorder.elapsedSeconds)}
          </div>

          {/* 상태 글자는 자리를 늘 잡아 둔다. 나타났다 사라지면 아래가 출렁인다. */}
          <div
            style={{
              minHeight: 20,
              marginTop: 4,
              fontSize: "var(--mobile-font-size-caption)",
              color: "var(--mobile-fg-muted)",
            }}
          >
            {recorder.state === "recording" && t("recorder.stateRecording")}
            {recorder.state === "paused" && t("recorder.statePaused")}
            {recorder.state === "requesting" && t("recorder.stateRequesting")}
            {recorder.state === "stopping" && t("recorder.stateStopping")}
            {/*
              쉬는 자리에서도 **왜 못 누르는지**를 여기서 말한다. 예전에는
              버튼만 흐려지고 이 줄은 비어 있어서, 색이 죽은 게 권한 때문인지
              회의 상태 때문인지 화면 어디에도 없었다.
            */}
            {!recorder.isActive && recorder.state !== "requesting" && recorder.state !== "stopping" && (
              <span style={idleHintTone(recorder.canStart)}>
                {idleHint(recorder.canStart, recorder.state, recorder.error)}
              </span>
            )}
          </div>
        </div>

        {/* 파형은 쉬는 동안에도 **가운데 평평한 선**으로 서 있는다. 비워 두면
            화면 한가운데가 죽고, 녹음을 눌러도 뭐가 달라졌는지 눈에 안 띈다. */}
        <canvas
          ref={recorder.canvasRef}
          className="vr-recorder__wave"
          data-idle={recorder.isActive ? undefined : "true"}
          height={180}
        />

        {/* 녹음 상태는 색과 파형으로만 드러난다. 소리로도 알려야 한다. */}
        <div className="vr-sr-only" role="status" aria-live="assertive">
          {recorder.error
            ? `${micErrorTitle(recorder.error.code)}. ${recorder.error.message}`
            : recordingStatus(recorder.state)}
        </div>

        {/*
          입력 레벨. 녹음 **중일 때만** 의미가 있다 — 멈춰 있을 때는 스트림이
          없어 peak 가 0 이고, 0 을 계속 보여주면 "마이크가 죽었다"로 읽힌다.
          이게 없으면 무음으로 한 시간을 녹음하고도 끝나야 안다.
        */}
        {recorder.isActive && (
          <div className="vr-level" role="img" aria-label={t("recorder.levelAria", { percent: Math.round(recorder.peak * 100) })}>
            <div className="vr-level__fill" style={{ width: `${Math.min(recorder.peak, 1) * 100}%` }} />
          </div>
        )}

        <div className="vr-recorder__foot">
          <div className="vr-recorder__controls">
          {recorder.isActive && (
            <Button
              variant="secondary"
              fit
              onClick={recorder.togglePause}
              icon={recorder.state === "paused" ? "play_arrow" : "pause"}
            >
              {recorder.state === "paused" ? t("recorder.resume") : t("recorder.pause")}
            </Button>
          )}

          {!recorder.isActive ? (
            <button
              className="vr-rec-button"
              onClick={handleStart}
              // 확실히 막힌 것만 잠근다. Safari 처럼 상태를 모르는 곳에서는
              // 눌러 봐야 알 수 있으므로 열어 둔다.
              disabled={
                !canRecord || preparing || recorder.state === "requesting" || !recorder.canStart
              }
              data-blocked={!recorder.canStart ? "true" : undefined}
              // 버튼이 흐려진 이유를 보조기술에도 남긴다.
              // `disabled` 만으로는 "왜" 가 전달되지 않는다.
              aria-label={recorder.canStart ? t("recorder.startAria") : t("recorder.startBlockedAria")}
              aria-describedby={!recorder.canStart ? MIC_TROUBLE_ID : undefined}
              type="button"
            >
              <Icon name={recorder.canStart ? "mic" : "mic_off"} />
            </button>
          ) : (
            <button
              className="vr-rec-button vr-rec-button--stop"
              onClick={recorder.stop}
              aria-label={t("recorder.stopAria")}
              type="button"
            >
              <Icon name="stop" />
            </button>
          )}

          {recorder.isActive && (
            <Button variant="ghost" fit onClick={handleCancel}>
              {t("common.cancel")}
            </Button>
          )}
        </div>

          {/*
            녹음 설정은 **녹음 전에만** 바꾼다. 도중에 마이크를 바꾸면 스트림을
            다시 열어야 해서 그 지점이 잘리고, 언어는 이미 시작한 세션에 못 미친다.

            칩이나 버튼으로 세우지 않는다 — 이 화면에서 누를 것은 녹음 버튼
            하나여야 한다. 글자로만 두고 필요할 때만 누른다.
          */}
          {!recorder.isActive && (
            <button type="button" className="vr-rec-prefs" onClick={() => setPicking(true)}>
              {prefs.micDeviceId ? t("recorder.micPicked") : t("recorder.micDefault")} · {languageLabel(language)}
            </button>
          )}
        </div>

        <div
          aria-live="polite"
          style={{
            minHeight: 20,
            fontSize: "var(--mobile-font-size-caption)",
            color: "var(--mobile-fg-muted)",
          }}
        >
          {progress && t("recorder.uploading", { percent: Math.round((progress.done / progress.total) * 100) })}
          {!progress && queue.pending > 0 && t("recorder.uploadPending", { count: queue.pending })}
        </div>

        {queue.failed > 0 && (
          <Notice kind="error" icon="error" title={t("recorder.uploadFailedTitle", { count: queue.failed })}>
            <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
              <Button variant="secondary" fit onClick={() => void uploader.retryFailed()}>
                {t("recorder.retryAll")}
              </Button>
              <Button variant="danger" fit onClick={() => void uploader.discardFailed()}>
                {t("recorder.discardAll")}
              </Button>
            </div>
          </Notice>
        )}
      </div>

      {picking && (
        <RecordingPrefsSheet
          micDeviceId={prefs.micDeviceId}
          account={account}
          onMicChange={(micDeviceId) => setPrefs({ micDeviceId })}
          onAccountChange={setAccount}
          onClose={() => setPicking(false)}
        />
      )}
    </div>
  );
}

/** 알림 띠와 [녹음] 버튼을 잇는 id. 버튼이 흐려진 이유를 보조기술이 읽게 한다. */
const MIC_TROUBLE_ID = "vr-mic-trouble";

/**
 * 마이크가 왜 안 되는지, 이 기기에서 무엇을 눌러야 풀리는지.
 *
 * ## 왜 문구를 여기서 만들지 않나
 *
 * 원인·절차·"다시 시도가 통하는가" 는 전부 `@core/recorder` 의 안내표에서 온다.
 * 화면마다 자기 문구를 쓰기 시작하면 데스크톱과 모바일이 서로 다른 해결책을
 * 말하게 되고, 어느 쪽이 맞는지 아무도 모르게 된다.
 *
 * ## [다시 시도] 를 아무 때나 띄우지 않는다
 *
 * 차단이 굳은 상태에서 이 버튼을 띄우면 사용자는 같은 자리를 반복해서 누르다
 * 앱이 고장 났다고 결론 낸다. 권한 창이 실제로 다시 뜰 수 있을 때만 띄운다.
 */
function MicTrouble({
  error,
  onRetry,
  onUseDefaultMic,
}: {
  error: RecorderError;
  onRetry?: () => void;
  onUseDefaultMic?: () => void;
}) {
  const { t } = useTranslation();
  const recovery = error.recovery;
  const tone = error.code === "interrupted" ? "warn" : "error";
  const retryable = recovery?.retryable ?? true;

  return (
    <div id={MIC_TROUBLE_ID}>
      <Notice
        kind={tone}
        icon={error.code === "interrupted" ? "phone_disabled" : "mic_off"}
        title={micErrorTitle(error.code)}
        className="mb-4"
      >
        <span>{error.message}</span>

        {recovery && recovery.steps.length > 0 && (
          <>
            <span className="vr-mic-trouble__lead">
              {recovery.needsSettings ? t("recorder.troubleLeadSettings") : t("recorder.troubleLead")}
            </span>
            <ol className="vr-mic-trouble__steps">
              {recovery.steps.map((step) => (
                <li key={step}>{step}</li>
              ))}
            </ol>
          </>
        )}

        {(onRetry || onUseDefaultMic) && (
          <span className="vr-mic-trouble__actions">
            {onRetry && retryable && (
              <Button variant="secondary" fit icon="refresh" onClick={onRetry}>
                {t("common.retry")}
              </Button>
            )}
            {onUseDefaultMic && error.code === "device_unavailable" && (
              <Button variant="secondary" fit icon="mic" onClick={onUseDefaultMic}>
                {t("recorder.useDefaultMic")}
              </Button>
            )}
          </span>
        )}
      </Notice>
    </div>
  );
}

/**
 * 아직 눌러 보지도 않았는데 이미 막혀 있는 경우.
 *
 * `getUserMedia` 를 부르지 않았으니 예외가 없다. 그래도 화면은 같은 말을 해야
 * 한다 — 안내는 엔진이 실패했을 때와 **같은 표**에서 나온다.
 */
function blockedBeforeStart(permission: MicPermissionState): RecorderError {
  const recovery = micRecoveryGuide("permission_blocked");

  return {
    code: "permission_blocked",
    message: recovery.cause,
    permission,
    recovery,
  };
}

/** 쉬는 상태에서 타이머 아래에 붙는 한 줄. 못 누르는 이유를 여기서 말한다. */
function idleHint(
  canStart: boolean,
  state: RecorderState,
  error: RecorderError | null,
): string {
  if (!canStart) return i18n.t("recorder.idleMicBlocked");
  if (state === "error" && error) return micErrorTitle(error.code);
  return "";
}

function idleHintTone(canStart: boolean): React.CSSProperties | undefined {
  return canStart ? undefined : { color: "var(--mobile-danger)", fontWeight: 600 };
}

/**
 * 스크린리더에 읽어 줄 녹음 상태.
 *
 * 화면에서는 빨간 점과 파형으로 드러나지만 그건 **보이는 사람만** 안다.
 * 특히 녹음이 끊긴 것(`error`)은 즉시 알아야 하는 사건이다.
 */
function recordingStatus(state: RecorderState): string {
  switch (state) {
    case "requesting":
      return i18n.t("recorder.srRequesting");
    case "recording":
      return i18n.t("recorder.srRecording");
    case "paused":
      return i18n.t("recorder.srPaused");
    case "stopping":
      return i18n.t("recorder.srStopping");
    case "error":
      return i18n.t("recorder.srError");
    case "idle":
      return "";
  }
}
