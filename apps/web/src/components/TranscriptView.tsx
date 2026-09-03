import { Icon } from "@/ui";
import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import i18n from "@/i18n";
import {
  changeSegmentSpeaker,
  colorIndexMap,
  editSegmentText,
  restoreOriginal,
  segmentAt,
  speakerViews,
  splitSegment,
  timeLabel,
  hasEdits,
} from "@core/domain";
import type { RecordingSession, SpeakerMapEntry, Transcript } from "@core/api";
import { SpeakerBar } from "./SpeakerBar";
import { EmptyState, Notice } from "./ui";

/**
 * Transcript view — chat style.
 *
 * **Source: sisyphus** `assets/webapp/meeting-recorder.js` 3316–3470 (`buildTranscriptMessagesHtml`).
 *
 * ## Two kinds of speaker change
 *
 * - Editing the **chip** at the top applies to all of that speaker's utterances
 * - Pressing the **name** on a bubble changes just that one line
 *
 * The second is for when STT split the speakers wrong.
 */
export function TranscriptView({
  session,
  friends,
  canEdit,
  playingMs,
  onPlaySegment,
  onSave,
}: {
  session: RecordingSession;
  friends: { id: string; name: string | null; email: string }[];
  canEdit: boolean;
  /** The current playback position (ms). null if it isn't this session */
  playingMs: number | null;
  onPlaySegment: (startMs: number) => void;
  onSave: (patch: { transcript?: Transcript; speaker_map?: Record<string, SpeakerMapEntry> }) => void;
}) {
  const { t } = useTranslation();
  const transcript = session.transcript;
  const speakerMap = session.speaker_map ?? {};

  const [editing, setEditing] = useState<number | null>(null);
  const [draft, setDraft] = useState("");
  const [menuFor, setMenuFor] = useState<number | null>(null);
  const [splitting, setSplitting] = useState<number | null>(null);

  const activeRef = useRef<HTMLDivElement | null>(null);

  const speakers = speakerViews(transcript, speakerMap);
  const colors = colorIndexMap(speakers);
  const segments = transcript?.segments ?? [];
  const activeIndex = playingMs === null ? -1 : segmentAt(segments, playingMs);

  // As playback advances, pull the current utterance into view
  useEffect(() => {
    activeRef.current?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }, [activeIndex]);

  if (!transcript || segments.length === 0) {
    return (
      <EmptyState
        icon="format_quote"
        title={emptyTitle(session.status)}
        desc={emptyDesc(session.status)}
      />
    );
  }

  function save(next: Partial<{ transcript: Transcript; speaker_map: Record<string, SpeakerMapEntry> }>) {
    onSave(next);
  }

  return (
    <div>
      <SpeakerBar
        speakers={speakers}
        friends={friends}
        canEdit={canEdit}
        onRename={(key, name) =>
          save({ speaker_map: { ...speakerMap, [key]: { ...speakerMap[key], name, account_id: speakerMap[key]?.account_id ?? null } } })
        }
        onAssign={(key, accountId) => {
          const friend = friends.find((f) => f.id === accountId);
          save({
            speaker_map: {
              ...speakerMap,
              [key]: friend
                ? { name: friend.name || friend.email, account_id: friend.id }
                : { name: speakerMap[key]?.name ?? key, account_id: null },
            },
          });
        }}
        onAdd={() => {
          let n = speakers.length + 1;
          while (speakerMap[`speaker_${n}`]) n += 1;
          save({ speaker_map: { ...speakerMap, [`speaker_${n}`]: { name: t("speaker.default", { n }), account_id: null } } });
        }}
        onRemove={(key) => {
          const moveTo = speakers.find((s) => s.key !== key)?.key;
          if (!moveTo) return;

          const nextMap = { ...speakerMap };
          delete nextMap[key];

          save({
            speaker_map: nextMap,
            transcript: {
              ...transcript,
              segments: transcript.segments.map((s) =>
                s.speaker === key ? { ...s, speaker: moveTo } : s,
              ),
            },
          });
        }}
      />

      {canEdit && hasEdits(transcript) && (
        <Notice kind="info" icon="history" className="mb-4">
          {t("transcript.editedNotice")}
          <button
            className="mobile-button mobile-button--ghost mobile-button--fit"
            style={{ marginLeft: 8 }}
            onClick={() => {
              const restored = restoreOriginal(transcript);
              if (restored) save({ transcript: restored });
            }}
          >
            {t("transcript.restoreOriginal")}
          </button>
        </Notice>
      )}

      <div className="vr-transcript">
        {segments.map((segment, index) => {
          const speaker = speakers.find((s) => s.key === segment.speaker);
          const active = index === activeIndex;

          return (
            <div
              key={index}
              ref={active ? activeRef : undefined}
              className={active ? "vr-msg vr-msg--active" : "vr-msg"}
              data-speaker={colors[segment.speaker] ?? 1}
            >
              <div className="vr-msg__head">
                <button
                  type="button"
                  className="vr-msg__speaker"
                  data-speaker={colors[segment.speaker] ?? 1}
                  onClick={() => canEdit && setMenuFor(menuFor === index ? null : index)}
                  disabled={!canEdit}
                  title={canEdit ? t("transcript.changeThisSpeaker") : undefined}
                >
                  {speaker?.name ?? segment.speaker}
                </button>

                <button
                  type="button"
                  className="vr-msg__time"
                  onClick={() => onPlaySegment(segment.start_ms)}
                  title={t("transcript.playFromHere")}
                >
                  {timeLabel(segment.start_ms)}
                </button>

                {canEdit && (
                  <div className="vr-msg__actions">
                    <button
                      type="button"
                      onClick={() => {
                        setEditing(index);
                        setDraft(segment.text);
                        setSplitting(null);
                      }}
                      title={t("transcript.editRemark")}
                    >
                      <Icon name="edit" />
                    </button>
                    <button
                      type="button"
                      onClick={() => {
                        setSplitting(splitting === index ? null : index);
                        setEditing(null);
                      }}
                      title={t("transcript.splitRemark")}
                    >
                      <Icon name="content_cut" />
                    </button>
                  </div>
                )}
              </div>

              {menuFor === index && (
                <>
                  <div className="vr-menu__backdrop" onClick={() => setMenuFor(null)} />
                  <div className="vr-menu vr-menu--inline" data-surface="raised">
                    <div className="vr-menu__title">{t("transcript.thisRemarkSpeaker")}</div>
                    <div className="vr-menu__list">
                      {speakers.map((option) => (
                        <button
                          key={option.key}
                          type="button"
                          className="vr-menu__item"
                          data-active={option.key === segment.speaker}
                          onClick={() => {
                            save({ transcript: changeSegmentSpeaker(transcript, index, option.key) });
                            setMenuFor(null);
                          }}
                        >
                          <span className="vr-speaker-chip__dot" data-speaker={option.colorIndex} />
                          {option.name}
                        </button>
                      ))}
                    </div>
                  </div>
                </>
              )}

              {editing === index ? (
                <div className="vr-msg__edit">
                  <textarea
                    className="mobile-field__input"
                    data-surface="sunken"
                    value={draft}
                    onChange={(e) => setDraft(e.target.value)}
                    rows={3}
                    autoFocus
                    style={{ fontFamily: "var(--font-sans)" }}
                  />
                  <div style={{ display: "flex", gap: 6, justifyContent: "flex-end", marginTop: 6 }}>
                    <button className="mobile-button mobile-button--ghost mobile-button--fit" onClick={() => setEditing(null)}>
                      {t("common.cancel")}
                    </button>
                    <button
                      className="mobile-button mobile-button--primary mobile-button--fit"
                      onClick={() => {
                        save({ transcript: editSegmentText(transcript, index, draft.trim()) });
                        setEditing(null);
                      }}
                    >
                      {t("common.save")}
                    </button>
                  </div>
                </div>
              ) : splitting === index ? (
                <SplitEditor
                  text={segment.text}
                  onCancel={() => setSplitting(null)}
                  onSplit={(charIndex) => {
                    save({ transcript: splitSegment(transcript, index, charIndex) });
                    setSplitting(null);
                  }}
                />
              ) : (
                <p className="vr-msg__text" onClick={() => onPlaySegment(segment.start_ms)}>
                  {segment.text}
                </p>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** Pick the split point between characters. */
function SplitEditor({
  text,
  onCancel,
  onSplit,
}: {
  text: string;
  onCancel: () => void;
  onSplit: (charIndex: number) => void;
}) {
  const { t } = useTranslation();
  const [at, setAt] = useState(Math.floor(text.length / 2));

  return (
    <div className="vr-msg__edit">
      <p className="vr-note" style={{ marginBottom: 6 }}>{t("transcript.splitPrompt")}</p>

      <p className="vr-msg__text" style={{ marginBottom: 8 }}>
        {text.slice(0, at)}
        <span className="vr-split-marker">|</span>
        {text.slice(at)}
      </p>

      <input
        type="range"
        min={1}
        max={Math.max(1, text.length - 1)}
        value={at}
        onChange={(e) => setAt(Number(e.target.value))}
        style={{ width: "100%" }}
      />

      <div style={{ display: "flex", gap: 6, justifyContent: "flex-end", marginTop: 6 }}>
        <button className="mobile-button mobile-button--ghost mobile-button--fit" onClick={onCancel}>{t("common.cancel")}</button>
        <button className="mobile-button mobile-button--primary mobile-button--fit" onClick={() => onSplit(at)}>
          {t("transcript.split")}
        </button>
      </div>
    </div>
  );
}

function emptyTitle(status: RecordingSession["status"]): string {
  switch (status) {
    case "transcribing":
      return i18n.t("transcript.emptyTranscribing");
    case "splitting":
      return i18n.t("transcript.emptySplitting");
    case "failed":
      return i18n.t("transcript.emptyFailed");
    case "uploaded":
      return i18n.t("transcript.emptyUploaded");
    default:
      return i18n.t("transcript.emptyNone");
  }
}

function emptyDesc(status: RecordingSession["status"]): string | undefined {
  switch (status) {
    case "transcribing":
      return i18n.t("transcript.emptyDescTranscribing");
    case "splitting":
      return i18n.t("transcript.emptyDescSplitting");
    case "uploaded":
      return i18n.t("transcript.emptyDescUploaded");
    default:
      return undefined;
  }
}
