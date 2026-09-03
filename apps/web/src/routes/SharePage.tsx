import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { useNavigate, useParams } from "react-router";
import i18n from "@/i18n";
import { GuestApiClient, GuestApiError } from "@core/api";
import type { Meeting, RecordingSession, ShareGate, SummarySource } from "@core/api";
import { TranscriptView } from "@/components/TranscriptView";
import { SummaryView } from "@/components/SummaryView";
import { AudioPlayerBar } from "@/components/AudioPlayerBar";
import { useAudioPlayer } from "@/hooks/useAudioPlayer";
import { Card, CardBody, Chip, EmptyState, Notice, Spinner } from "@/components/ui";
import { formatDuration } from "@/lib/format";
import { Icon } from "@/ui";

const guest = new GuestApiClient();

/** Gone when the tab closes. The right lifetime for a screen viewed briefly via a share link. */
function storageKey(token: string) {
  return `vr.guest.${token.slice(0, 16)}`;
}

/**
 * The guest screen entered via a share link.
 *
 * **Source: new.** sisyphus had the server string-substitute static HTML to
 * plant `window.__GUEST_LINK_DATA__`, interpolating error messages straight
 * into HTML. That approach was not ported.
 *
 * The transcript/summary views use **the exact same components** as the
 * signed-in screens — a separate guest-only view would fork into two copies.
 */
export function SharePage() {
  const { t } = useTranslation();
  const { token = "" } = useParams();
  const navigate = useNavigate();
  const player = useAudioPlayer();

  const [gate, setGate] = useState<ShareGate | null>(null);
  const [meeting, setMeeting] = useState<Meeting | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fatal, setFatal] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [selectedSessionId, setSelected] = useState<string | null>(null);

  const loadMeeting = useCallback(async () => {
    try {
      setMeeting(await guest.meeting());
      setError(null);
      return true;
    } catch (e) {
      // The session dropped. Back to the entry screen.
      guest.token = null;
      sessionStorage.removeItem(storageKey(token));
      setMeeting(null);

      if (e instanceof GuestApiError && e.status !== 401) setError(e.message);
      return false;
    }
  }, [token]);

  useEffect(() => {
    if (!token) return;

    const saved = sessionStorage.getItem(storageKey(token));

    void (async () => {
      if (saved) {
        guest.token = saved;
        if (await loadMeeting()) return;
      }

      try {
        setGate(await guest.gate(token));
      } catch (e) {
        setFatal(describe(e));
      }
    })();
  }, [token, loadMeeting]);

  async function enter(form: { display_name?: string; email?: string; pincode?: string }) {
    setBusy(true);
    setError(null);

    try {
      const result = await guest.enter(token, form);

      // Signed-in accounts don't create guest sessions. Account permissions take precedence.
      if (result.mode === "account" && result.redirect) {
        navigate(result.redirect, { replace: true });
        return;
      }

      if (result.guest_token) {
        guest.token = result.guest_token;
        sessionStorage.setItem(storageKey(token), result.guest_token);
        await loadMeeting();
      }
    } catch (e) {
      if (e instanceof GuestApiError && (e.status === 404 || e.status === 410)) {
        setFatal(describe(e));
      } else {
        setError(describe(e));
      }
    } finally {
      setBusy(false);
    }
  }

  if (fatal) {
    return (
      <Shell>
        <Card>
          <CardBody>
            <EmptyState icon="link_off" title={fatal} desc={t("share.fatalDesc")} />
          </CardBody>
        </Card>
      </Shell>
    );
  }

  if (meeting) {
    return (
      <MeetingView
        meeting={meeting}
        player={player}
        selectedSessionId={selectedSessionId}
        onSelect={setSelected}
        error={error}
        onLeave={async () => {
          await guest.leave().catch(() => {});
          sessionStorage.removeItem(storageKey(token));
          guest.token = null;
          setMeeting(null);
          setGate(await guest.gate(token).catch(() => null));
        }}
      />
    );
  }

  if (!gate) {
    return (
      <Shell>
        <Spinner label={t("share.checking")} />
      </Shell>
    );
  }

  return (
    <Shell>
      <Card>
        <CardBody>
          <h1 style={{ margin: 0, fontSize: 18, fontWeight: 700, color: "var(--text-primary)" }}>
            {t("share.sharedTitle")}
          </h1>
          <p className="vr-note" style={{ marginTop: 6 }}>
            {gate.granted_role === "contributor"
              ? t("share.roleContributor")
              : t("share.roleViewer")}
          </p>

          {error && <Notice kind="error" icon="error" className="mb-4">{error}</Notice>}

          <ShareGateForm gate={gate} busy={busy} onSubmit={enter} />
        </CardBody>
      </Card>
    </Shell>
  );
}

function ShareGateForm({
  gate,
  busy,
  onSubmit,
}: {
  gate: ShareGate;
  busy: boolean;
  onSubmit: (form: { display_name?: string; email?: string; pincode?: string }) => void;
}) {
  const { t } = useTranslation();
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [pincode, setPincode] = useState("");

  return (
    <form
      style={{ display: "flex", flexDirection: "column", gap: 10, marginTop: 16 }}
      onSubmit={(e) => {
        e.preventDefault();
        onSubmit({
          display_name: gate.require_name ? name.trim() : undefined,
          email: gate.require_email ? email.trim() : undefined,
          pincode: gate.require_pincode ? pincode.trim() : undefined,
        });
      }}
    >
      {gate.require_name && (
        <Field label={t("share.fieldName")}>
          <input
            className="mobile-field__input"
            data-surface="sunken"
            style={{ fontFamily: "var(--font-sans)" }}
            value={name}
            onChange={(e) => setName(e.target.value)}
            maxLength={60}
            required
            autoFocus
          />
        </Field>
      )}

      {gate.require_email && (
        <Field label={t("share.fieldEmail")}>
          <input
            type="email"
            className="mobile-field__input"
            data-surface="sunken"
            style={{ fontFamily: "var(--font-sans)" }}
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </Field>
      )}

      {gate.require_pincode && (
        <Field label={t("share.fieldPin")}>
          <input
            className="mobile-field__input"
            data-surface="sunken"
            style={{ fontFamily: "var(--font-mono)", letterSpacing: 4 }}
            value={pincode}
            onChange={(e) => setPincode(e.target.value.replace(/\D/g, "").slice(0, 6))}
            inputMode="numeric"
            autoComplete="off"
            required
          />
        </Field>
      )}

      <button type="submit" className="mobile-button mobile-button--primary mobile-button--full" disabled={busy}>
        {busy ? t("share.opening") : t("share.openNotes")}
      </button>
    </form>
  );
}

function MeetingView({
  meeting,
  player,
  selectedSessionId,
  onSelect,
  error,
  onLeave,
}: {
  meeting: Meeting;
  player: ReturnType<typeof useAudioPlayer>;
  selectedSessionId: string | null;
  onSelect: (id: string) => void;
  error: string | null;
  onLeave: () => void;
}) {
  const { t } = useTranslation();
  const [tab, setTab] = useState<"summary" | "transcript">("summary");

  const sessions = meeting.recording_sessions ?? [];
  const transcribed = sessions.filter((s) => s.transcript?.segments?.length);
  const selected = transcribed.find((s) => s.id === selectedSessionId) ?? transcribed[0] ?? null;
  const canEdit = meeting.role === "contributor";

  function play(session: RecordingSession, startMs = 0) {
    // The server doesn't give Viewers an audio_href
    if (session.audio_href) player.play(session.id, session.audio_href, startMs);
  }

  return (
    <Shell>
      {error && <Notice kind="error" icon="error" className="mb-4">{error}</Notice>}

      <Card className="mb-4">
        <CardBody>
          <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 12 }}>
            <div style={{ minWidth: 0 }}>
              <h1 style={{ margin: 0, fontSize: 18, fontWeight: 700, color: "var(--text-primary)" }}>
                {meeting.title || t("common.untitled")}
              </h1>
              <div style={{ display: "flex", gap: 6, marginTop: 8, flexWrap: "wrap" }}>
                <Chip kind="info">{meeting.role}</Chip>
                {meeting.total_duration_seconds > 0 && (
                  <Chip kind="neutral">{t("share.totalDuration", { duration: formatDuration(meeting.total_duration_seconds) })}</Chip>
                )}
              </div>
            </div>

            <button className="mobile-button mobile-button--ghost mobile-button--fit" onClick={onLeave}>{t("share.leave")}</button>
          </div>
        </CardBody>
      </Card>

      <div style={{ display: "flex", gap: 6, marginBottom: 12 }}>
        <button
          className={tab === "summary" ? "mobile-button mobile-button--secondary mobile-button--fit" : "mobile-button mobile-button--secondary mobile-button--fit"}
          onClick={() => setTab("summary")}
          aria-pressed={tab === "summary"}
        >
          {t("share.tabSummary")}
        </button>
        <button
          className={tab === "transcript" ? "mobile-button mobile-button--secondary mobile-button--fit" : "mobile-button mobile-button--secondary mobile-button--fit"}
          onClick={() => setTab("transcript")}
          aria-pressed={tab === "transcript"}
        >
          {t("share.tabTranscript")} {transcribed.length > 0 && `(${transcribed.length})`}
        </button>
      </div>

      <Card>
        <CardBody>
          {tab === "summary" ? (
            <SummaryView
              meeting={meeting}
              sessions={sessions}
              // Guests can't create summaries. The server has no such route either.
              canEdit={false}
              busy={false}
              onSummarize={() => {}}
              onJump={(source: SummarySource) => {
                const session = sessions.find((s) => s.id === source.session_id);
                if (session) {
                  onSelect(session.id);
                  play(session, source.start_ms);
                }
              }}
            />
          ) : selected ? (
            <>
              {transcribed.length > 1 && (
                <div style={{ display: "flex", gap: 6, marginBottom: 12, flexWrap: "wrap" }}>
                  {transcribed.map((session) => (
                    <button
                      key={session.id}
                      className={
                        session.id === selected.id
                          ? "mobile-button mobile-button--primary mobile-button--fit"
                          : "mobile-button mobile-button--secondary mobile-button--fit"
                      }
                      onClick={() => onSelect(session.id)}
                    >
                      {t("share.recordingIndex", { index: session.session_index })}
                    </button>
                  ))}
                </div>
              )}

              <TranscriptView
                session={selected}
                friends={[]}
                canEdit={canEdit}
                playingMs={player.sessionId === selected.id ? player.currentMs : null}
                onPlaySegment={(startMs) => play(selected, startMs)}
                onSave={() => {}}
              />
            </>
          ) : (
            <EmptyState icon="format_quote" title={t("share.noTranscript")} />
          )}
        </CardBody>
      </Card>

      <AudioPlayerBar player={player} />
    </Shell>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div className="vr-app">
      <header className="vr-app__header">
        <span className="vr-app__brand">
          <Icon name="mic" />
          KHALA VOICE
        </span>
      </header>
      <main className="vr-app__main">{children}</main>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label style={{ display: "block" }}>
      <span className="mobile-field__label" style={{ display: "block", marginBottom: 5 }}>{label}</span>
      {children}
    </label>
  );
}

function describe(error: unknown): string {
  if (error instanceof GuestApiError) {
    if (error.status === 404) return i18n.t("share.linkNotFound");
    if (error.status === 410) return i18n.t("share.linkExpired");
    return error.message;
  }

  return error instanceof Error ? error.message : i18n.t("share.openFailed");
}
