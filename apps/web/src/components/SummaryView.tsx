import { useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import i18n from "@/i18n";
import type { Meeting, RecordingSession, SummaryData, SummarySource } from "@core/api";
import { Chip, EmptyState, Notice } from "@/components/ui";
import { Icon } from "@/ui";

/**
 * AI 요약.
 *
 * **출처: sisyphus** n8n `autosquad-meeting-summary.json` 의 출력 스키마를
 * 그대로 그린다 ([04-pipeline.md](../../../../docs/04-pipeline.md)).
 *
 * ## 근거를 누르면 그 지점이 재생된다
 *
 * 이 제품의 핵심 UX다. `source` 는 서버가 실제 전사와 대조해 확인한 것만 붙는다
 * (지어낸 인용은 서버에서 걸러진다). 그래서 **`source` 가 있으면 반드시 재생된다**.
 * 없으면 근거 줄 자체를 그리지 않는다 — 눌러도 안 되는 버튼을 두지 않는다.
 */
export function SummaryView({
  meeting,
  sessions,
  canEdit,
  busy,
  onSummarize,
  onJump,
}: {
  meeting: Meeting;
  sessions: RecordingSession[];
  canEdit: boolean;
  busy: boolean;
  onSummarize: () => void;
  onJump: (source: SummarySource) => void;
}) {
  const { t } = useTranslation();
  const data = meeting.summary_data;
  const transcribed = sessions.some((s) => s.transcript?.segments?.length);

  if (!data) {
    return (
      <EmptyState
        icon="summarize"
        title={t("summary.emptyTitle")}
        desc={
          transcribed
            ? t("summary.emptyDescTranscribed")
            : t("summary.emptyDescNoTranscript")
        }
      >
        {canEdit && transcribed && (
          <button className="mobile-button mobile-button--primary mobile-button--full" onClick={onSummarize} disabled={busy}>
            {busy ? t("summary.summarizing") : t("summary.create")}
          </button>
        )}
      </EmptyState>
    );
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
      <div>
        <p style={{ fontSize: 16, lineHeight: 1.6, color: "var(--text-primary)", margin: 0 }}>
          {data.one_liner}
        </p>

        {data.key_topics?.length > 0 && (
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginTop: 12 }}>
            {data.key_topics.map((topic) => (
              <Chip key={topic} kind="neutral">{topic}</Chip>
            ))}
          </div>
        )}
      </div>

      {(data.chunk_count ?? 1) > 1 && (
        <Notice kind="info" icon="info">
          <Trans t={t} i18nKey="summary.chunkNotice" values={{ count: data.chunk_count }} components={{ strong: <strong /> }} />
        </Notice>
      )}

      {(data.skipped_session_ids?.length ?? 0) > 0 && (
        <Notice kind="warn" icon="info">
          {t("summary.skippedNotice", { count: data.skipped_session_ids!.length })}
        </Notice>
      )}

      <Sourced
        title={t("summary.decisions")}
        icon="gavel"
        items={data.decisions}
        render={(d) => d.text}
        onJump={onJump}
      />

      <Sourced
        title={t("summary.actionItems")}
        icon="task_alt"
        items={data.action_items}
        render={(a) => (
          <>
            {a.what}
            {(a.who || a.due) && (
              <span className="mobile-row__meta" style={{ marginLeft: 8, fontSize: 12 }}>
                {[a.who, a.due].filter(Boolean).join(" · ")}
              </span>
            )}
          </>
        )}
        onJump={onJump}
      />

      <Plain title={t("summary.facts")} icon="fact_check" items={data.facts} />
      <Plain title={t("summary.openQuestions")} icon="help" items={data.open_questions} />
      <Plain title={t("summary.nextSteps")} icon="arrow_forward" items={data.next_steps} />

      <footer
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: 12,
          paddingTop: 16,
          borderTop: "var(--hairline-width) solid var(--border-subtle)",
        }}
      >
        <span className="mobile-row__meta" style={{ fontSize: 12 }}>
          {[data.model, data.generated_at && new Date(data.generated_at).toLocaleString(i18n.language)]
            .filter(Boolean)
            .join(" · ")}
        </span>

        {canEdit && (
          <button className="mobile-button mobile-button--secondary mobile-button--fit" onClick={onSummarize} disabled={busy}>
            {busy ? t("summary.summarizing") : t("summary.resummarize")}
          </button>
        )}
      </footer>
    </div>
  );
}

function Sourced<T extends { source: SummarySource | null }>({
  title,
  icon,
  items,
  render,
  onJump,
}: {
  title: string;
  icon: string;
  items: T[];
  render: (item: T) => React.ReactNode;
  onJump: (source: SummarySource) => void;
}) {
  if (!items?.length) return null;

  return (
    <section>
      <SectionTitle icon={icon}>{title}</SectionTitle>

      <ul className="vr-summary__list">
        {items.map((item, i) => (
          <li key={i} className="vr-summary__item">
            <div className="vr-summary__body">{render(item)}</div>
            {item.source && <SourceLine source={item.source} onJump={onJump} />}
          </li>
        ))}
      </ul>
    </section>
  );
}

function SourceLine({
  source,
  onJump,
}: {
  source: SummarySource;
  onJump: (source: SummarySource) => void;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);

  return (
    <div className="vr-summary__source">
      <button
        type="button"
        className="vr-summary__jump"
        onClick={() => onJump(source)}
        title={t("summary.playFromHere")}
      >
        <Icon name="play_arrow" />
        {source.speaker} · {source.time_label}
      </button>

      <button
        type="button"
        className="vr-summary__quote-toggle"
        onClick={() => setOpen(!open)}
        aria-expanded={open}
      >
        {open ? t("summary.collapseQuote") : t("summary.showQuote")}
      </button>

      {open && <blockquote className="vr-summary__quote">{source.quote}</blockquote>}
    </div>
  );
}

function Plain({ title, icon, items }: { title: string; icon: string; items: string[] }) {
  if (!items?.length) return null;

  return (
    <section>
      <SectionTitle icon={icon}>{title}</SectionTitle>
      <ul className="vr-summary__list">
        {items.map((item, i) => (
          <li key={i} className="vr-summary__item">
            <div className="vr-summary__body">{item}</div>
          </li>
        ))}
      </ul>
    </section>
  );
}

function SectionTitle({ icon, children }: { icon: string; children: React.ReactNode }) {
  return (
    <h3 className="vr-summary__title">
      <Icon name={icon} />
      {children}
    </h3>
  );
}

export type { SummaryData };
