import { useCallback, useEffect, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { api } from "@/lib/api";
import { useRoutes } from "@/lib/routes";
import { LabelSelect, TopicSelect } from "@/components/TaxonomySelect";
import { Button, Sheet } from "@/ui";
import type { Label, Meeting, Topic } from "@core/api";

/**
 * The modal for editing a meeting's title and taxonomy.
 *
 * Opens when the title is pressed on the recording screen. Why no input field
 * in the recording screen's body: the star of that screen is the record
 * button, and a form in the middle blurs "what should I do now".
 *
 * The taxonomy list comes from the server as **the meeting owner's**
 * (`GET /meetings/:id/taxonomy`). Attaching my taxonomy to someone else's
 * meeting would keep it out of the owner's archive search.
 */
export function MeetingTitleSheet({
  meeting,
  onClose,
  onSaved,
  onError,
}: {
  meeting: Meeting;
  onClose: () => void;
  onSaved: (meeting: Meeting) => void;
  onError: (message: string | null) => void;
}) {
  const { t } = useTranslation();
  const routes = useRoutes();
  const [title, setTitle] = useState(meeting.title ?? "");
  const [topics, setTopics] = useState<Topic[]>([]);
  const [labels, setLabels] = useState<Label[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    void api
      .meetingTaxonomy(meeting.id)
      .then((r) => {
        setTopics(r.topics);
        setLabels(r.labels);
      })
      .catch(() => {});
  }, [meeting.id]);

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

  async function done() {
    const next = title.trim();

    // If the title is unchanged, send no request — changing only the taxonomy and closing is the more common case
    if (next !== (meeting.title ?? "").trim()) await save({ title: next });

    onClose();
  }

  /**
   * A new topic. **Only topics are created here** — this is the flow of
   * deciding "what meeting is this" right as it opens, and a round trip to the
   * taxonomy screen would break it. Labels are different in nature (tags that
   * span several), so they're only picked from what already exists.
   */
  const createTopic = useCallback(
    async (name: string) => {
      try {
        const topic = await api.createTopic({ name });
        setTopics((prev) => [...prev, topic]);
        return topic;
      } catch (e) {
        onError(e instanceof Error ? e.message : t("meetingTitle.topicCreateError"));
        return null;
      }
    },
    [onError],
  );

  return (
    <Sheet title={t("meetingTitle.title")} onClose={onClose}>
      <div className="vr-filter">
        <div className="vr-filter__group">
          <span className="vr-filter__label">{t("meetingTitle.titleLabel")}</span>
          <input
            className="mobile-field__input"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder={t("meetingTitle.titlePlaceholder")}
            aria-label={t("meetingTitle.titlePlaceholder")}
            autoFocus
          />
        </div>

        <TopicSelect
          topics={topics}
          value={meeting.topic_id}
          onChange={(topicId) => void save({ topic_id: topicId })}
          onCreate={createTopic}
        />

        <LabelSelect
          labels={labels}
          value={meeting.label_ids}
          onChange={(labelIds) => void save({ label_ids: labelIds })}
        />

        {labels.length === 0 && (
          <p className="vr-note vr-note--small">
            <Trans t={t} i18nKey="meetingTitle.labelsHint" components={{ link: <a href={routes.taxonomy} /> }} />
          </p>
        )}

        <div className="vr-filter__actions">
          <Button full onClick={() => void done()} pending={saving} loadingLabel={t("common.saving")}>
            {t("meetingTitle.done")}
          </Button>
        </div>
      </div>
    </Sheet>
  );
}
