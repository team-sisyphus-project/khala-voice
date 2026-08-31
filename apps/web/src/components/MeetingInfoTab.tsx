import { useCallback, useEffect, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { api } from "@/lib/api";
import { useRoutes } from "@/lib/routes";
import { Tag } from "@/components/Tag";
import { VisibilityPanel } from "@/components/VisibilityPanel";
import { EmptyState, Notice } from "@/components/ui";
import type { CurrentAccount, Friend, Label, Meeting, Topic } from "@core/api";

/**
 * 회의 정보 탭 — 분류(Contributor+)와 공개 범위(Reviewer).
 *
 * 분류 목록은 **회의 owner 의 것**을 서버에서 받는다 (`GET /meetings/:id/taxonomy`).
 * 내 분류를 남의 회의에 붙이면 owner 의 아카이브 검색에 그 회의가 안 걸린다.
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

  // 다른 사람이 고쳤거나 다른 회의로 옮겨오면 입력칸도 따라간다
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
      {/* 제목을 고치는 자리는 **여기 하나뿐이다.** 상단바 캡슐이 늘 제목을
          보여주고 있어서, 본문에 또 두면 같은 글자가 두 벌로 보인다. */}
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

      {/* 패널이 스스로 Reviewer 인지 검열한다 */}
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
