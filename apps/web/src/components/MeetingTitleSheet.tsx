import { useCallback, useEffect, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { api } from "@/lib/api";
import { useRoutes } from "@/lib/routes";
import { LabelSelect, TopicSelect } from "@/components/TaxonomySelect";
import { Button, Sheet } from "@/ui";
import type { Label, Meeting, Topic } from "@core/api";

/**
 * 회의 제목·분류를 고치는 모달.
 *
 * 녹음 화면에서 제목을 누르면 열린다. 녹음 화면 본문에 입력칸을 두지 않는 이유:
 * 그 화면의 주인공은 녹음 버튼이고, 폼이 끼면 "지금 뭘 해야 하는지"가 흐려진다.
 *
 * 분류 목록은 **회의 owner 의 것**을 서버에서 받는다 (`GET /meetings/:id/taxonomy`).
 * 내 분류를 남의 회의에 붙이면 owner 의 아카이브 검색에 그 회의가 안 걸린다.
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

    // 제목이 그대로면 요청을 보내지 않는다 — 분류만 바꾸고 닫는 경우가 더 잦다
    if (next !== (meeting.title ?? "").trim()) await save({ title: next });

    onClose();
  }

  /**
   * 새 토픽. **토픽만 여기서 만든다** — 회의를 열자마자 "이건 무슨 회의인가"를
   * 정하는 흐름이라 분류 화면까지 다녀오게 하면 끊긴다. 라벨은 성격이 달라서
   * (여러 개를 걸치는 꼬리표) 만들어진 것 중에 고르기만 한다.
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
