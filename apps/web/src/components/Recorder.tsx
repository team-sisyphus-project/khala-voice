import { useCallback, useEffect, useState } from "react";
import { useRecorder } from "@/hooks/useRecorder";
import { formatDuration } from "@/lib/format";
import { api, uploader } from "@/lib/api";
import { Notice } from "./ui";
import { Button, Icon } from "@/ui";
import { RecordingPrefsSheet } from "./RecordingPrefsSheet";
import { usePrefs } from "@/hooks/usePrefs";
import { useAccount } from "@/hooks/useAccount";
import { languageLabel, resolveLanguage } from "@/lib/prefs";
import type { RecorderResult, RecorderState } from "@core/recorder";
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
      setPrepareError(error instanceof Error ? error.message : "녹음을 시작하지 못했습니다");
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
            ? "이 회의는 조회 전용입니다."
            : "완료된 회의입니다. 녹음하려면 상태를 '진행 중'으로 되돌리세요."}
        </Notice>
      )}

      {recorder.error && (
        <Notice kind="error" icon="error" title="녹음 오류" className="mb-4">
          {recorder.error.message}
        </Notice>
      )}

      {prepareError && (
        <Notice kind="error" icon="error" className="mb-4">{prepareError}</Notice>
      )}

      {recorder.wasInterrupted && (
        <Notice kind="warn" icon="phone_disabled" title="녹음이 중단되었습니다" className="mb-4">
          전화나 다른 앱이 마이크를 가져갔습니다. 그때까지 녹음된 내용은 저장했습니다.
        </Notice>
      )}

      {showCountdown && (
        <Notice kind="warn" icon="timer" className="mb-4">
          최대 녹음 시간까지 {formatDuration(recorder.remainingSeconds)} 남았습니다.
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
            {recorder.state === "recording" && "녹음 중"}
            {recorder.state === "paused" && "일시정지"}
            {recorder.state === "requesting" && "마이크 준비 중"}
            {recorder.state === "stopping" && "저장 중"}
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
          {recordingStatus(recorder.state)}
        </div>

        {/*
          입력 레벨. 녹음 **중일 때만** 의미가 있다 — 멈춰 있을 때는 스트림이
          없어 peak 가 0 이고, 0 을 계속 보여주면 "마이크가 죽었다"로 읽힌다.
          이게 없으면 무음으로 한 시간을 녹음하고도 끝나야 안다.
        */}
        {recorder.isActive && (
          <div className="vr-level" role="img" aria-label={`입력 레벨 ${Math.round(recorder.peak * 100)}%`}>
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
              {recorder.state === "paused" ? "재개" : "일시정지"}
            </Button>
          )}

          {!recorder.isActive ? (
            <button
              className="vr-rec-button"
              onClick={handleStart}
              disabled={!canRecord || preparing || recorder.state === "requesting"}
              aria-label="녹음 시작"
              type="button"
            >
              <Icon name="mic" />
            </button>
          ) : (
            <button
              className="vr-rec-button vr-rec-button--stop"
              onClick={recorder.stop}
              aria-label="녹음 종료"
              type="button"
            >
              <Icon name="stop" />
            </button>
          )}

          {recorder.isActive && (
            <Button variant="ghost" fit onClick={handleCancel}>
              취소
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
              {prefs.micDeviceId ? "마이크 고름" : "기본 마이크"} · {languageLabel(language)}
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
          {progress && `업로드 중 ${Math.round((progress.done / progress.total) * 100)}%`}
          {!progress && queue.pending > 0 && `업로드 대기 ${queue.pending}건`}
        </div>

        {queue.failed > 0 && (
          <Notice kind="error" icon="error" title={`${queue.failed}건의 업로드에 실패했습니다`}>
            <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
              <Button variant="secondary" fit onClick={() => void uploader.retryFailed()}>
                모두 재시도
              </Button>
              <Button variant="danger" fit onClick={() => void uploader.discardFailed()}>
                모두 삭제
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

/**
 * 스크린리더에 읽어 줄 녹음 상태.
 *
 * 화면에서는 빨간 점과 파형으로 드러나지만 그건 **보이는 사람만** 안다.
 * 특히 녹음이 끊긴 것(`error`)은 즉시 알아야 하는 사건이다.
 */
function recordingStatus(state: RecorderState): string {
  switch (state) {
    case "requesting":
      return "마이크 권한을 요청하는 중입니다";
    case "recording":
      return "녹음 중입니다";
    case "paused":
      return "녹음을 일시정지했습니다";
    case "stopping":
      return "녹음을 마무리하는 중입니다";
    case "error":
      return "녹음이 중단되었습니다";
    case "idle":
      return "";
  }
}
