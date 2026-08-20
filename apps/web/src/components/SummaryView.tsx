import { useState } from "react";
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
  const data = meeting.summary_data;
  const transcribed = sessions.some((s) => s.transcript?.segments?.length);

  if (!data) {
    return (
      <EmptyState
        icon="summarize"
        title="아직 요약이 없습니다"
        desc={
          transcribed
            ? "전사를 바탕으로 AI가 결정사항과 할 일을 뽑아냅니다."
            : "먼저 녹음을 전사하세요. 전사가 있어야 요약할 수 있습니다."
        }
      >
        {canEdit && transcribed && (
          <button className="mobile-button mobile-button--primary mobile-button--full" onClick={onSummarize} disabled={busy}>
            {busy ? "요약하는 중…" : "요약 만들기"}
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
          긴 회의라 <strong>{data.chunk_count}개로 나눠 요약</strong>한 뒤 합쳤습니다.
          빠진 구간은 없습니다.
        </Notice>
      )}

      {(data.skipped_session_ids?.length ?? 0) > 0 && (
        <Notice kind="warn" icon="info">
          전사가 없는 녹음 {data.skipped_session_ids!.length}개는 요약에서 빠졌습니다.
        </Notice>
      )}

      <Sourced
        title="결정사항"
        icon="gavel"
        items={data.decisions}
        render={(d) => d.text}
        onJump={onJump}
      />

      <Sourced
        title="할 일"
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

      <Plain title="주요 사실" icon="fact_check" items={data.facts} />
      <Plain title="열린 질문" icon="help" items={data.open_questions} />
      <Plain title="다음 단계" icon="arrow_forward" items={data.next_steps} />

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
          {[data.model, data.generated_at && new Date(data.generated_at).toLocaleString("ko-KR")]
            .filter(Boolean)
            .join(" · ")}
        </span>

        {canEdit && (
          <button className="mobile-button mobile-button--secondary mobile-button--fit" onClick={onSummarize} disabled={busy}>
            {busy ? "요약하는 중…" : "다시 요약"}
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
  const [open, setOpen] = useState(false);

  return (
    <div className="vr-summary__source">
      <button
        type="button"
        className="vr-summary__jump"
        onClick={() => onJump(source)}
        title="이 발언 지점부터 재생"
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
        {open ? "원문 접기" : "원문 보기"}
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
