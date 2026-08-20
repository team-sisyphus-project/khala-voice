import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { api } from "@/lib/api";
import { useRoutes } from "@/lib/routes";
import { formatBytes, formatDuration, formatDateTime } from "@/lib/format";
import { AppShell } from "@/components/AppShell";
import { RecorderPanel } from "@/components/Recorder";
import { TranscriptView } from "@/components/TranscriptView";
import { AudioPlayerBar } from "@/components/AudioPlayerBar";
import { SummaryView } from "@/components/SummaryView";
import { ShareDialog } from "@/components/ShareDialog";
import { MeetingInfoTab } from "@/components/MeetingInfoTab";
import { MeetingTitleSheet } from "@/components/MeetingTitleSheet";
import { useAudioPlayer } from "@/hooks/useAudioPlayer";
import { Button, EmptyState, Icon, Notice, Row, SegmentedControl, Section, StatusChip } from "@/ui";
import type {
  CurrentAccount,
  Friend,
  Meeting,
  RecordingSession,
  SessionStatus,
  SpeakerMapEntry,
  SummarySource,
  Transcript,
} from "@core/api";

type Tab = "record" | "sessions" | "transcript" | "summary" | "info";

type MeetingDetailPageProps = {
  /** 주소에 id 가 없는 자리(회의 탭)에서 쓴다. 없으면 라우트 파라미터를 본다. */
  meetingId?: string;
  /**
   * **최상위 탭으로 그린다.** 회의 탭은 뒤로가기가 없고, 제목은 큰 헤더가 아니라
   * 그 아래 작은 줄에 선다 (누르면 모달로 고친다).
   */
  asTab?: boolean;
};

export function MeetingDetailPage({ meetingId, asTab = false }: MeetingDetailPageProps = {}) {
  const routes = useRoutes();
  const params = useParams();
  const id = meetingId ?? params.id ?? "";
  const navigate = useNavigate();
  const player = useAudioPlayer();

  const [meeting, setMeeting] = useState<Meeting | null>(null);
  const [friends, setFriends] = useState<Friend[]>([]);
  const [me, setMe] = useState<CurrentAccount | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("record");
  const [selectedSessionId, setSelected] = useState<string | null>(null);
  const [summarizing, setSummarizing] = useState(false);
  const [sharing, setSharing] = useState(false);
  const [editing, setEditing] = useState(false);
  const waitingFrom = useRef<{ stamp: string | null; errorAt: string | null } | null>(null);

  const load = useCallback(async () => {
    try {
      const data = await api.getMeeting(id);
      setMeeting(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "회의를 불러오지 못했습니다");
    }
  }, [id]);

  useEffect(() => {
    void load();
    void api.friends().then((r) => setFriends(r.friends)).catch(() => {});
    void api.me().then(setMe).catch(() => {});
  }, [load]);

  const sessions = useMemo(() => meeting?.recording_sessions ?? [], [meeting]);

  // 전사 탭은 완료된 세션만 다룬다
  const transcribed = useMemo(
    () => sessions.filter((s) => s.transcript?.segments?.length),
    [sessions],
  );

  const selected = useMemo(
    () => transcribed.find((s) => s.id === selectedSessionId) ?? transcribed[0] ?? null,
    [transcribed, selectedSessionId],
  );

  // 서버에서 진행 중인 작업이 있을 때만 따라간다. SSE 를 붙이기 전까지의 임시 방편.
  useEffect(() => {
    const busy =
      summarizing ||
      sessions.some((s) => ["uploaded", "splitting", "transcribing"].includes(s.status));

    if (!busy) return;

    const timer = setInterval(() => void load(), 5000);
    return () => clearInterval(timer);
  }, [sessions, summarizing, load]);

  // 요약 대기 해제 — **큐잉 시점 이후에 값이 바뀌었을 때만**.
  // 이미 요약이 있는 회의에서 [다시 요약] 을 누르면 기존 타임스탬프가 있으므로
  // "값이 있는가"로 판단하면 즉시 풀려 버린다.
  const summaryStamp = meeting?.summary_data?.generated_at ?? null;
  const summaryErrorAt = meeting?.last_summary_error?.at ?? null;

  useEffect(() => {
    if (!summarizing) return;

    const before = waitingFrom.current;
    if (!before) return;
    if (summaryStamp === before.stamp && summaryErrorAt === before.errorAt) return;

    setSummarizing(false);
    waitingFrom.current = null;

    if (summaryErrorAt && summaryErrorAt !== before.errorAt) {
      setError("요약을 만들지 못했습니다. 잠시 후 다시 시도해 주세요.");
    }
  }, [summaryStamp, summaryErrorAt, summarizing]);

  /** 화자·전사 편집을 저장한다. 화면은 먼저 바꾸고 서버는 뒤따른다. */
  const saveTranscript = useCallback(
    async (
      session: RecordingSession,
      patch: { transcript?: Transcript; speaker_map?: Record<string, SpeakerMapEntry> },
    ) => {
      // 낙관적 갱신 — 편집이 즉시 반영돼야 손맛이 산다
      setMeeting((prev) =>
        prev
          ? {
              ...prev,
              recording_sessions: prev.recording_sessions?.map((s) =>
                s.id === session.id
                  ? {
                      ...s,
                      transcript: patch.transcript ?? s.transcript,
                      speaker_map: patch.speaker_map ?? s.speaker_map,
                    }
                  : s,
              ),
            }
          : prev,
      );

      try {
        await api.updateSpeakers(session.id, patch);
      } catch {
        // 저장에 실패하면 서버 값으로 되돌린다
        setError("편집을 저장하지 못했습니다");
        void load();
      }
    },
    [load],
  );

  /** 요약을 큐잉한다. 완료는 아래 폴링이 따라간다. */
  async function summarize() {
    if (!meeting) return;

    waitingFrom.current = {
      stamp: meeting.summary_data?.generated_at ?? null,
      errorAt: meeting.last_summary_error?.at ?? null,
    };

    setSummarizing(true);
    setError(null);

    try {
      await api.summarize(meeting.id);
    } catch (e) {
      setSummarizing(false);
      waitingFrom.current = null;
      setError(e instanceof Error ? e.message : "요약을 시작하지 못했습니다");
    }
  }

  /** 요약 근거를 누르면 그 발언 지점부터 재생한다. */
  function jumpTo(source: SummarySource) {
    const session = sessions.find((s) => s.id === source.session_id);
    const href = session?.audio_href;

    if (!session || !href) {
      setError("이 발언의 녹음 파일을 찾을 수 없습니다");
      return;
    }

    setSelected(session.id);
    player.play(session.id, href, source.start_ms);
  }

  if (error && !meeting) {
    return (
      <AppShell active="meetings" title="회의">
        <Notice tone="error" title="열지 못했습니다">{error}</Notice>
      </AppShell>
    );
  }

  if (!meeting) {
    return (
      <AppShell active="meetings" title={asTab ? "새 회의" : "회의"} onBack={asTab ? undefined : () => navigate(routes.archive)}>
        <EmptyState title="불러오는 중" />
      </AppShell>
    );
  }

  const readOnly = meeting.role === "viewer";
  // 공유 링크 발급은 Reviewer 만. 서버도 lv0 으로 다시 판정한다.
  const canShare = meeting.role === "reviewer";
  const playingMs = player.sessionId === selected?.id ? player.currentMs : null;

  return (
    <AppShell
      active="meetings"
      title={asTab ? "새 회의" : meeting.title || "제목 없음"}
      onBack={asTab ? undefined : () => navigate(routes.archive)}
      // 녹음 탭만 한 화면에 딱 맞춘다. 나머지 탭은 내용이 길어 스크롤해야 한다.
      fill={tab === "record"}
      actions={
        // 상단바 액션은 아이콘 버튼이다 — 글자를 넣으면 제목 자리를 잡아먹는다
        <>
          {/* 세션 쿠키 인증이라 그냥 링크면 된다. core 에 다운로드 헬퍼를 만들지 않는다 —
              만들면 프레임워크 비의존이어야 할 core 가 브라우저 API 에 묶인다. */}
          <a
            className="mobile-top-app-bar__icon-button"
            href={`/api/meetings/${meeting.id}/export.md`}
            download
            aria-label="마크다운으로 내보내기"
            title="내보내기"
          >
            <Icon name="download" />
          </a>

          {canShare && (
            <button
              className="mobile-top-app-bar__icon-button"
              onClick={() => setSharing(true)}
              aria-label="공유 링크"
              title="공유"
              type="button"
            >
              <Icon name="share" />
            </button>
          )}
        </>
      }
    >
      {error && <Notice tone="error">{error}</Notice>}

      {/*
        탭 모드에서는 큰 헤더가 "새 회의" 라서 제목이 어디에도 없다. 헤더 바로 아래
        작은 줄로 둔다 — **누르면 모달**이 열려 제목과 분류를 고친다.
        뎁스 모드에서는 상단바 캡슐이 이미 제목을 들고 있어 여기 두지 않는다.
      */}
      {asTab && (
        <button
          type="button"
          className="vr-meeting-title"
          onClick={() => !readOnly && setEditing(true)}
          disabled={readOnly}
          aria-label={readOnly ? undefined : "제목과 분류 바꾸기"}
        >
          <span className="vr-meeting-title__text">{meeting.title || "제목 없음"}</span>
          {!readOnly && <Icon name="edit" />}
        </button>
      )}

      {/*
        상태·공개범위·분류 칩을 첫 화면에 늘어놓지 않는다. **[정보] 탭에 이미 있고**,
        녹음 화면의 주인공은 녹음 버튼이다. 제목 줄 하나면 "어느 회의인지"는 충분하다.
      */}

      <SegmentedControl
        value={tab}
        onChange={setTab}
        options={[
          { value: "record" as Tab, label: "녹음" },
          { value: "sessions" as Tab, label: sessions.length > 0 ? `세션 ${sessions.length}` : "세션" },
          {
            value: "transcript" as Tab,
            label: transcribed.length > 0 ? `전사 ${transcribed.length}` : "전사",
          },
          { value: "summary" as Tab, label: "요약" },
          // Viewer 에게는 바꿀 것이 없다. 패널도 스스로 한 번 더 검열한다.
          ...(readOnly ? [] : [{ value: "info" as Tab, label: "정보" }]),
        ]}
      />

      <Section>
          {tab === "record" && <RecorderPanel meeting={meeting} onSessionCreated={load} />}

          {tab === "sessions" && (
            <SessionList
              sessions={sessions}
              canEdit={!readOnly}
              onChanged={load}
              onPlay={(session) =>
                session.audio_href && player.play(session.id, session.audio_href)
              }
            />
          )}

          {tab === "transcript" && (
            <>
              {transcribed.length > 1 && (
                <div style={{ display: "flex", gap: 6, marginBottom: 12, flexWrap: "wrap" }}>
                  {transcribed.map((session) => (
                    <button
                      key={session.id}
                      className={
                        session.id === selected?.id
                          ? "mobile-button mobile-button--primary mobile-button--fit"
                          : "mobile-button mobile-button--secondary mobile-button--fit"
                      }
                      onClick={() => setSelected(session.id)}
                    >
                      {partLabel(session)}
                    </button>
                  ))}
                </div>
              )}

              {transcribed.length > 1 && (
                <Notice tone="info">
                  긴 녹음이 나뉘어 전사됐습니다. <strong>조각마다 화자 번호가 따로</strong> 매겨지므로
                  조각 1의 화자 1과 조각 2의 화자 1이 다른 사람일 수 있습니다.
                </Notice>
              )}

              {selected ? (
                <TranscriptView
                  session={selected}
                  friends={friends}
                  canEdit={!readOnly}
                  playingMs={playingMs}
                  onPlaySegment={(startMs) => {
                    if (selected.audio_href) player.play(selected.id, selected.audio_href, startMs);
                  }}
                  onSave={(patch) => void saveTranscript(selected, patch)}
                />
              ) : (
                <EmptyState
                  title="아직 전사된 녹음이 없습니다"
                  description="세션 탭에서 전사를 시작하세요."
                />
              )}
            </>
          )}

          {tab === "info" && (
            <MeetingInfoTab
              meeting={meeting}
              friends={friends}
              me={me}
              onSaved={setMeeting}
              onError={setError}
              onLostAccess={() => navigate(routes.meetings, { replace: true })}
            />
          )}

          {tab === "summary" && (
            <SummaryView
              meeting={meeting}
              sessions={sessions}
              canEdit={!readOnly}
              busy={summarizing}
              onSummarize={() => void summarize()}
              onJump={jumpTo}
            />
          )}
      </Section>

      <AudioPlayerBar player={player} label={selected ? partLabel(selected) : undefined} />

      {editing && meeting && (
        <MeetingTitleSheet
          meeting={meeting}
          onClose={() => setEditing(false)}
          onSaved={setMeeting}
          onError={setError}
        />
      )}

      {sharing && (
        <ShareDialog meeting={meeting} onClose={() => setSharing(false)} onMeetingChanged={load} />
      )}
    </AppShell>
  );
}

function partLabel(session: RecordingSession): string {
  const part = session.metadata?.["part"] as { label?: string } | undefined;
  return part?.label ? `녹음 ${session.session_index} · ${part.label}` : `녹음 ${session.session_index}`;
}

function SessionList({
  sessions,
  canEdit,
  onChanged,
  onPlay,
}: {
  sessions: RecordingSession[];
  canEdit: boolean;
  onChanged: () => void;
  onPlay: (session: RecordingSession) => void;
}) {
  const [busy, setBusy] = useState<string | null>(null);

  async function transcribe(id: string) {
    setBusy(id);
    try {
      await api.transcribeSession(id);
      onChanged();
    } finally {
      setBusy(null);
    }
  }

  if (sessions.length === 0) {
    return <EmptyState title="아직 녹음이 없습니다" description="녹음 탭에서 시작하세요." />;
  }

  return (
    <>
      {sessions.map((session) => (
        <Row
          key={session.id}
          icon={statusIcon(session.status)}
          title={
            <>
              {partLabel(session)}{" "}
              <span style={{ fontWeight: 400, color: "var(--mobile-fg-muted)" }}>
                {formatDuration(session.duration_seconds)}
              </span>
            </>
          }
          meta={
            <>
              {formatDateTime(new Date(session.started_at_unix * 1000).toISOString())}
              {session.file_size_bytes ? ` · ${formatBytes(session.file_size_bytes)}` : ""}
              {session.error_message ? ` · ${session.error_message}` : ""}
            </>
          }
          trailing={
            <span style={{ display: "flex", alignItems: "center", gap: 6 }}>
              <StatusChip status={session.status} label={sessionLabel(session.status)} />

              {canEdit && needsTranscription(session.status) && (
                <Button
                  variant="secondary"
                  fit
                  onClick={() => void transcribe(session.id)}
                  pending={busy === session.id}
                >
                  {session.status === "failed"
                    ? "다시 전사"
                    : session.status === "completed"
                      ? "재전사"
                      : "전사"}
                </Button>
              )}

              {session.audio_href && (
                <Button variant="ghost" fit square icon="play_arrow" onClick={() => onPlay(session)} />
              )}
            </span>
          }
        />
      ))}
    </>
  );
}

function needsTranscription(status: SessionStatus): boolean {
  return status === "uploaded" || status === "failed" || status === "completed";
}

// devkanban 아이콘 세트에 있는 이름만 쓴다. 없는 이름은 기본 아이콘으로 떨어진다.
function statusIcon(status: SessionStatus): string {
  switch (status) {
    case "recording":
      return "radio_button_checked";
    case "uploaded":
      return "check";
    case "splitting":
    case "transcribing":
      return "schedule";
    case "completed":
      return "check_circle";
    case "failed":
      return "error";
  }
}


function sessionLabel(status: SessionStatus): string {
  switch (status) {
    case "recording":
      return "녹음 중";
    case "uploaded":
      return "업로드됨";
    case "splitting":
      return "분할 중";
    case "transcribing":
      return "전사 중";
    case "completed":
      return "완료";
    case "failed":
      return "실패";
  }
}
