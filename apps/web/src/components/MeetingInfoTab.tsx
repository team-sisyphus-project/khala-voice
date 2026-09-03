import { useCallback, useEffect, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { api } from "@/lib/api";
import { useRoutes } from "@/lib/routes";
import { Tag } from "@/components/Tag";
import { VisibilityPanel } from "@/components/VisibilityPanel";
import { EmptyState, Notice } from "@/components/ui";
import type { CurrentAccount, Friend, Label, Meeting, Topic } from "@core/api";

/**
 * The meeting info tab — taxonomy (Contributor+) and visibility (Reviewer).
 *
 * The taxonomy list comes from the server as **the meeting owner's**
 * (`GET /meetings/:id/taxonomy`). Attaching my taxonomy to someone else's
 * meeting would keep it out of the owner's archive search.
 */
export function MeetingInfoTab({
  meeting,
  friends,
  me,
  onSaved,
  onError,
  onLostAccess,
}: {
  meeting: Meeting;
  friends: Friend[];
  me: CurrentAccount | null;
  onSaved: (meeting: Meeting) => void;
  onError: (message: string | null) => void;
  onLostAccess: () => void;
}) {
  const { t } = useTranslation();
  const routes = useRoutes();
  const [topics, setTopics] = useState<Topic[]>([]);
  const [labels, setLabels] = useState<Label[]>([]);
  const [saving, setSaving] = useState(false);
  const [title, setTitle] = useState(meeting.title ?? "");

  const canEdit = meeting.role !== "viewer";

  // If someone else edited it, or we moved to a different meeting, the input follows
  useEffect(() => {
    setTitle(meeting.title ?? "");
  }, [meeting.id, meeting.title]);

  const saveTitle = useCallback(async () => {
    const next = title.trim();

    if (next === (meeting.title ?? "").trim()) return;

    try {
      onSaved(await api.updateMeeting(meeting.id, { title: next }));
    } catch (e) {
      onError(e instanceof Error ? e.message : t("meetingInfo.titleSaveError"));
    }
  }, [meeting.id, meeting.title, title, onSaved, onError]);

  useEffect(() => {
    if (!canEdit) return;

    void api
      .meetingTaxonomy(meeting.id)
      .then((r) => {
        setTopics(r.topics);
        setLabels(r.labels);
      })
      .catch(() => {});
  }, [meeting.id, canEdit]);

  const save = useCallback(
    async (body: Record<string, unknown>) => {
      setSaving(true);
      onError(null);

      try {
        onSaved(await api.updateMeeting(meeting.id, body));
      } catch (e) {
        onError(e instanceof Error ? e.message : t("common.saveError"));
      } finally {
        setSaving(false);
      }
    },
    [meeting.id, onSaved, onError],
  );

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
      {/* This is **the one place** to edit the title. The top-bar capsule
          always shows it, so another copy in the body would show the same text twice. */}
      {canEdit && (
        <section>
          <h3 className="mobile-section__title">{t("meetingInfo.titleLabel")}</h3>
          <input
            className="mobile-field__input"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            onBlur={saveTitle}
            placeholder={t("meetingInfo.titlePlaceholder")}
            aria-label={t("meetingInfo.titlePlaceholder")}
          />
        </section>
      )}

      {canEdit && (
        <section>
          <h3 className="mobile-section__title">{t("meetingInfo.taxonomyLabel")}</h3>

          {topics.length === 0 && labels.length === 0 ? (
            <EmptyState
              icon="sell"
              title={t("meetingInfo.noTaxonomyTitle")}
              desc={t("meetingInfo.noTaxonomyDesc")}
            >
              <a className="mobile-button mobile-button--secondary mobile-button--fit" href={routes.taxonomy}>
                {t("meetingInfo.createTaxonomy")}
              </a>
            </EmptyState>
          ) : (
            <>
              {topics.length > 0 && (
                <div className="vr-filter__row" style={{ marginTop: 8 }}>
                  <span className="mobile-field__label">{t("meetingInfo.topic")}</span>
                  {topics.map((topic) => (
                    <Tag
                      key={topic.id}
                      item={topic}
                      kind="topic"
                      pressed={meeting.topic_id === topic.id}
                      onClick={() =>
                        void save({
                          topic_id: meeting.topic_id === topic.id ? null : topic.id,
                        })
                      }
                    />
                  ))}
                </div>
              )}

              {labels.length > 0 && (
                <div className="vr-filter__row" style={{ marginTop: 8 }}>
                  <span className="mobile-field__label">{t("meetingInfo.label")}</span>
                  {labels.map((label) => {
                    const on = meeting.label_ids.includes(label.id);

                    return (
                      <Tag
                        key={label.id}
                        item={label}
                        pressed={on}
                        onClick={() =>
                          void save({
                            label_ids: on
                              ? meeting.label_ids.filter((x) => x !== label.id)
                              : [...meeting.label_ids, label.id],
                          })
                        }
                      />
                    );
                  })}
                </div>
              )}
            </>
          )}

          {saving && (
            <p className="vr-note" style={{ fontSize: 12, marginTop: 8 }} aria-live="polite">
              {t("common.saving")}
            </p>
          )}
        </section>
      )}

      {/* The panel checks for Reviewer on its own */}
      <VisibilityPanel
        meeting={meeting}
        friends={friends}
        me={me}
        onSaved={onSaved}
        onError={onError}
        onLostAccess={onLostAccess}
      />

      {meeting.role === "contributor" && (
        <Notice kind="info" icon="info">
          <Trans t={t} i18nKey="meetingInfo.reviewerOnlyNote" components={{ strong: <strong /> }} />
        </Notice>
      )}
    </div>
  );
}
