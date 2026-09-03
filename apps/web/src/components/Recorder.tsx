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
import { resolveLanguage } from "@/lib/prefs";
import { micRecoveryGuide } from "@core/recorder";
import { errorTitle, guideText } from "@/lib/recorderGuide";
import type {
  MicPermissionState,
  RecorderError,
  RecorderResult,
  RecorderState,
} from "@core/recorder";
import type { Meeting } from "@core/api";

/**
 * Recording controls.
 *
 * ## Loss-prevention order
 *
 *     1. Create the session before recording starts
 *     2. Recording ends → Blob
 *     3. Save to IndexedDB (Uploader.enqueue)
 *     4. presign → S3 PUT → register with the server
 *
 * Why step 1 comes first: if we tried to create the session after recording
 * ends and the network drops, we're left with a Blob that has nowhere to go.
 * Creating it up front means even offline there's a known target to enqueue to.
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
   * The microphone lives on the **device**; the transcription language lives on
   * the **account**.
   *
   * The mic is tied to a place (a meeting-room PC always uses that room's mic),
   * so it stays on the device. Language is tied to a person, so it must follow
   * them across devices.
   */
  const [prefs, setPrefs] = usePrefs();
  const { account, setAccount } = useAccount();
  const language = resolveLanguage(account);

  const canRecord = meeting.status === "active" && meeting.role !== "viewer";

  const discardSession = useCallback((id: string | null) => {
    if (!id) return;
    // Ignore failures — at worst an empty session lingers on the server, and that's no reason to block the user
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

  // If recording fails to start, the pre-created session is orphaned.
  // Delete it for errors where no data could have been produced (mic denied, unsupported).
  useEffect(() => {
    if (!recorder.error || !sessionId) return;
    if (recorder.error.code === "interrupted") return; // this one has data

    discardSession(sessionId);
    setSessionId(null);
  }, [recorder.error, sessionId, discardSession]);

  /**
   * Fall back to the default device when the chosen mic has disappeared.
   *
   * This state does not heal on its own — the stored `micDeviceId` keeps
   * pointing at a missing device, so [Record] fails at the same spot no matter
   * how many times it's pressed. Without a way back on screen, the user has no
   * idea the cause lives somewhere in the recording settings.
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
      // Secure the session before recording starts
      const session = await api.createSession(meeting.id, {
        started_at_unix: Math.floor(Date.now() / 1000),
        // Transcription needs to know the language. Relying on the server default
        // (ko-KR) would mistranscribe an entire meeting in another language and
        // burn credits for nothing.
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
        Even before any error, some things must be said **before the press**.
        On a device where permission is already blocked, pressing [Record] just
        fails with no prompt ever appearing.
      */}
      {!recorder.error && !recorder.canStart && canRecord && (
        <MicTrouble error={blockedBeforeStart(recorder.permission)} />
      )}

      {prepareError && (
        <Notice kind="error" icon="error" className="mb-4">{prepareError}</Notice>
      )}

      {/* An interruption also arrives as `error`, where MicTrouble shows the full
          recovery steps. This slot only renders when that isn't present — never
          say the same thing twice. */}
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

          {/* The status text always reserves its space. If it popped in and out, everything below would jump. */}
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
              Even at rest, this is where we say **why the button can't be
              pressed**. Previously the button just dimmed while this line stayed
              empty, and nothing on screen said whether the dead color was about
              permissions or the meeting's status.
            */}
            {!recorder.isActive && recorder.state !== "requesting" && recorder.state !== "stopping" && (
              <span style={idleHintTone(recorder.canStart)}>
                {idleHint(recorder.canStart, recorder.state, recorder.error)}
              </span>
            )}
          </div>
        </div>

        {/* The waveform stays up even at rest, as a **flat line through the
            center**. Left empty, the middle of the screen goes dead and pressing
            record produces no visible change. */}
        <canvas
          ref={recorder.canvasRef}
          className="vr-recorder__wave"
          data-idle={recorder.isActive ? undefined : "true"}
          height={180}
        />

        {/* Recording state only shows through color and the waveform. It must be announced audibly too. */}
        <div className="vr-sr-only" role="status" aria-live="assertive">
          {recorder.error
            ? `${errorTitle(t, recorder.error.code)}. ${guideText(t, recorder.error.message)}`
            : recordingStatus(recorder.state)}
        </div>

        {/*
          Input level. Only meaningful **while recording** — when stopped there
          is no stream, peak is 0, and showing a constant 0 reads as "the mic is
          dead". Without this, you could record an hour of silence and only find
          out at the end.
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
              // Lock only what is definitely blocked. Where the state is unknown
              // (e.g. Safari), pressing is the only way to find out, so leave it enabled.
              disabled={
                !canRecord || preparing || recorder.state === "requesting" || !recorder.canStart
              }
              data-blocked={!recorder.canStart ? "true" : undefined}
              // Expose why the button is dimmed to assistive tech as well.
              // `disabled` alone doesn't convey the "why".
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
            Recording preferences change **only before recording**. Switching
            mics mid-recording means reopening the stream, which cuts at that
            point, and a language change can't reach a session already underway.

            Not styled as a chip or button — the record button should be the one
            pressable thing on this screen. Plain text, pressed only when needed.
          */}
          {!recorder.isActive && (
            <button type="button" className="vr-rec-prefs" onClick={() => setPicking(true)}>
              {prefs.micDeviceId ? t("recorder.micPicked") : t("recorder.micDefault")} · {t(`language.names.${language}`)}
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

/** Id linking the notice strip to the [Record] button, so assistive tech can read why the button is dimmed. */
const MIC_TROUBLE_ID = "vr-mic-trouble";

/**
 * Why the mic isn't working, and what to press on this device to fix it.
 *
 * ## Why the copy isn't authored here
 *
 * Cause, steps, and "will retry work" all come from the guide table in
 * `@core/recorder`. Once each screen starts writing its own copy, desktop and
 * mobile end up prescribing different fixes and nobody knows which is right.
 *
 * ## [Retry] is not shown indiscriminately
 *
 * Showing this button while the block is permanent makes users press the same
 * spot over and over and conclude the app is broken. Show it only when the
 * permission prompt can actually appear again.
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
        title={errorTitle(t, error.code)}
        className="mb-4"
      >
        <span>{guideText(t, error.message)}</span>

        {recovery && recovery.steps.length > 0 && (
          <>
            <span className="vr-mic-trouble__lead">
              {recovery.needsSettings ? t("recorder.troubleLeadSettings") : t("recorder.troubleLead")}
            </span>
            <ol className="vr-mic-trouble__steps">
              {recovery.steps.map((step) => (
                <li key={step.key}>{guideText(t, step)}</li>
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
 * Already blocked before the button was ever pressed.
 *
 * `getUserMedia` hasn't been called, so there's no exception. The screen must
 * still say the same thing — the guidance comes from the **same table** as when
 * the engine actually fails.
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

/** The one line under the timer while idle. This is where we say why the button can't be pressed. */
function idleHint(
  canStart: boolean,
  state: RecorderState,
  error: RecorderError | null,
): string {
  if (!canStart) return i18n.t("recorder.idleMicBlocked");
  if (state === "error" && error) return errorTitle(i18n.t, error.code);
  return "";
}

function idleHintTone(canStart: boolean): React.CSSProperties | undefined {
  return canStart ? undefined : { color: "var(--mobile-danger)", fontWeight: 600 };
}

/**
 * Recording state read out to screen readers.
 *
 * On screen it shows through the red dot and the waveform, but only **sighted
 * users** get that. A dropped recording (`error`) in particular is an event
 * that must be known immediately.
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
