import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { useNavigate, useParams } from "react-router";
import i18n from "@/i18n";
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
import { KhalaSendSheet } from "@/components/KhalaSendSheet";
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
  /** Used where the address carries no id (the meetings tab). Falls back to the route param. */
  meetingId?: string;
  /**
   * **Render as a top-level tab.** The meetings tab has no back button, and the
   * title sits on a small line below the large header (press it to edit in a
   * modal).
   */
  asTab?: boolean;
};

export function MeetingDetailPage({ meetingId, asTab = false }: MeetingDetailPageProps = {}) {
  const { t } = useTranslation();
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
  const [sendingKhala, setSendingKhala] = useState(false);

  // If Khala is off or not yet connected, omit the button entirely — never show something that fails when pressed
  const [khalaReady, setKhalaReady] = useState(false);

  useEffect(() => {
    void api
      .khalaStatus()
      .then((s) => setKhalaReady(s.enabled && s.connected))
      .catch(() => setKhalaReady(false));
  }, []);
  const waitingFrom = useRef<{ stamp: string | null; errorAt: string | null } | null>(null);

  const load = useCallback(async () => {
    try {
      const data = await api.getMeeting(id);
      setMeeting(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : t("meetingDetail.loadError"));
    }
  }, [id, t]);

  useEffect(() => {
    void load();
    void api.friends().then((r) => setFriends(r.friends)).catch(() => {});
    void api.me().then(setMe).catch(() => {});
  }, [load]);

  const sessions = useMemo(() => meeting?.recording_sessions ?? [], [meeting]);

  // The transcript tab only deals with completed sessions
  const transcribed = useMemo(
    () => sessions.filter((s) => s.transcript?.segments?.length),
    [sessions],
  );

  const selected = useMemo(
    () => transcribed.find((s) => s.id === selectedSessionId) ?? transcribed[0] ?? null,
    [transcribed, selectedSessionId],
  );

  // Poll only while the server has work in flight. A stopgap until SSE is wired up.
  useEffect(() => {
    const busy =
      summarizing ||
      sessions.some((s) => ["uploaded", "splitting", "transcribing"].includes(s.status));

    if (!busy) return;

    const timer = setInterval(() => void load(), 5000);
    return () => clearInterval(timer);
  }, [sessions, summarizing, load]);

  // Release the summary wait — **only when the value changed after queueing**.
  // Pressing [Summarize again] on a meeting that already has a summary means an
  // existing timestamp is present, so judging by "is there a value" would
  // release immediately.
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
      setError(t("meetingDetail.summaryFailed"));
    }
  }, [summaryStamp, summaryErrorAt, summarizing, t]);

  /** Save speaker/transcript edits. The screen changes first; the server follows. */
  const saveTranscript = useCallback(
    async (
      session: RecordingSession,
      patch: { transcript?: Transcript; speaker_map?: Record<string, SpeakerMapEntry> },
    ) => {
      // Optimistic update — edits must land instantly for the interaction to feel right
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
        // On save failure, revert to the server's values
        setError(t("meetingDetail.saveEditError"));
        void load();
      }
    },
    [load, t],
  );

  /** Queue a summary. Completion is tracked by the polling below. */
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
      setError(e instanceof Error ? e.message : t("meetingDetail.summarizeStartError"));
    }
  }

  /** Pressing a summary source plays back from that utterance. */
  function jumpTo(source: SummarySource) {
    const session = sessions.find((s) => s.id === source.session_id);
    const href = session?.audio_href;

    if (!session || !href) {
      setError(t("meetingDetail.clipNotFound"));
      return;
    }

    setSelected(session.id);
    player.play(session.id, href, source.start_ms);
  }

  if (error && !meeting) {
    return (
      <AppShell active="meetings" title={t("meetingDetail.title")}>
        <Notice tone="error" title={t("meetingDetail.openFailedTitle")}>{error}</Notice>
      </AppShell>
    );
  }

  if (!meeting) {
    return (
      <AppShell active="meetings" title={asTab ? t("meetingDetail.newMeeting") : t("meetingDetail.title")} onBack={asTab ? undefined : () => navigate(routes.archive)}>
        <EmptyState title={t("meetingDetail.loading")} />
      </AppShell>
    );
  }

  const readOnly = meeting.role === "viewer";
  // Only a Reviewer can issue share links. The server re-checks at lv0 too.
  const canShare = meeting.role === "reviewer";
  const playingMs = player.sessionId === selected?.id ? player.currentMs : null;

  return (
    <AppShell
      active="meetings"
      title={asTab ? t("meetingDetail.newMeeting") : meeting.title || t("common.untitled")}
      onBack={asTab ? undefined : () => navigate(routes.archive)}
      // Only the record tab fits exactly in one screen. The other tabs are long and must scroll.
      fill={tab === "record"}
      actions={
        // Top-bar actions are icon buttons — text would eat into the title's space
        <>
          {/* Session-cookie auth, so a plain link suffices. No download helper in
              core — that would tie the framework-agnostic core to browser APIs. */}
          <a
            className="mobile-top-app-bar__icon-button"
            href={`/api/meetings/${meeting.id}/export.md`}
            download
            aria-label={t("meetingDetail.exportAria")}
            title={t("meetingDetail.exportTitle")}
          >
            <Icon name="download" />
          </a>

          {canShare && (
            <button
              className="mobile-top-app-bar__icon-button"
              onClick={() => setSharing(true)}
              aria-label={t("meetingDetail.shareAria")}
              title={t("meetingDetail.shareTitle")}
              type="button"
            >
              <Icon name="share" />
            </button>
          )}

          {/* Visible only when the Khala integration is on and connected.
              The server re-checks permission on send — this button is a convenience. */}
          {canShare && khalaReady && (
            <button
              className="mobile-top-app-bar__icon-button"
              onClick={() => setSendingKhala(true)}
              aria-label={t("meetingDetail.khalaSendAria")}
              title={t("meetingDetail.khalaSendTitle")}
              type="button"
            >
              <Icon name="send" />
            </button>
          )}
        </>
      }
    >
      {error && <Notice tone="error">{error}</Notice>}

      {/*
        In tab mode the large header reads "New meeting", so the title appears
        nowhere. Put it on a small line right under the header — **press to
        open a modal** for editing the title and taxonomy. In depth mode the
        top-bar capsule already holds the title, so it isn't placed here.
      */}
      {asTab && (
        <button
          type="button"
          className="vr-meeting-title"
          onClick={() => !readOnly && setEditing(true)}
          disabled={readOnly}
          aria-label={readOnly ? undefined : t("meetingDetail.editTitleAria")}
        >
          <span className="vr-meeting-title__text">{meeting.title || t("common.untitled")}</span>
          {!readOnly && <Icon name="edit" />}
        </button>
      )}

      {/*
        Don't spread status/visibility/taxonomy chips across the first screen.
        **They're already in the [Info] tab**, and the star of the recording
        screen is the record button. One title line is enough to say "which
        meeting this is".
      */}

      <SegmentedControl
        value={tab}
        onChange={setTab}
        options={[
          { value: "record" as Tab, label: t("meetingDetail.tabRecord") },
          { value: "sessions" as Tab, label: sessions.length > 0 ? t("meetingDetail.tabSessionsCount", { count: sessions.length }) : t("meetingDetail.tabSessions") },
          {
            value: "transcript" as Tab,
            label: transcribed.length > 0 ? t("meetingDetail.tabTranscriptCount", { count: transcribed.length }) : t("meetingDetail.tabTranscript"),
          },
          { value: "summary" as Tab, label: t("meetingDetail.tabSummary") },
          // A Viewer has nothing to change. The panel double-checks on its own as well.
          ...(readOnly ? [] : [{ value: "info" as Tab, label: t("meetingDetail.tabInfo") }]),
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
                  <Trans t={t} i18nKey="meetingDetail.splitNotice" components={{ strong: <strong /> }} />
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
                  title={t("meetingDetail.noTranscriptTitle")}
                  description={t("meetingDetail.noTranscriptDesc")}
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

      {sendingKhala && meeting && (
        <KhalaSendSheet meeting={meeting} onClose={() => setSendingKhala(false)} />
      )}

      {sharing && (
        <ShareDialog meeting={meeting} onClose={() => setSharing(false)} onMeetingChanged={load} />
      )}
    </AppShell>
  );
}

function partLabel(session: RecordingSession): string {
  const part = session.metadata?.["part"] as { label?: string } | undefined;
  return part?.label
    ? i18n.t("meetingDetail.partLabelNamed", { index: session.session_index, label: part.label })
    : i18n.t("meetingDetail.partLabel", { index: session.session_index });
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
  const { t } = useTranslation();
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
    return <EmptyState title={t("meetingDetail.noSessionsTitle")} description={t("meetingDetail.noSessionsDesc")} />;
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
                    ? t("meetingDetail.retranscribeFailed")
                    : session.status === "completed"
                      ? t("meetingDetail.retranscribe")
                      : t("meetingDetail.transcribe")}
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

// Use only names in the devkanban icon set. Unknown names fall back to the default icon.
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
      return i18n.t("meetingDetail.sessionRecording");
    case "uploaded":
      return i18n.t("meetingDetail.sessionUploaded");
    case "splitting":
      return i18n.t("meetingDetail.sessionSplitting");
    case "transcribing":
      return i18n.t("meetingDetail.sessionTranscribing");
    case "completed":
      return i18n.t("meetingDetail.sessionCompleted");
    case "failed":
      return i18n.t("meetingDetail.sessionFailed");
  }
}
