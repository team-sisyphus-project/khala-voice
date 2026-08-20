import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { api } from "@/lib/api";
import { useRoutes } from "@/lib/routes";
import { AppShell } from "@/components/AppShell";
import { Tag } from "@/components/Tag";
import { Card, CardBody, EmptyState, Notice, Spinner } from "@/components/ui";
import type { ColorKey, Label, Topic } from "@core/api";
import { Icon } from "@/ui";

const COLORS: ColorKey[] = [
  "red", "orange", "yellow", "green", "teal",
  "blue", "indigo", "violet", "purple", "gray",
];

/**
 * 분류 관리 — 토픽과 라벨. **아카이브 안쪽의 화면이다.**
 *
 * 분류는 아카이브를 검색하려고 붙이는 것이라 주 메뉴에 둘 만큼 자주 열지 않는다.
 * 아카이브 필터 옆에서 들어온다.
 *
 * 토픽은 회의당 하나, 라벨은 여러 개다. 아카이브 검색의 주 필터라
 * **지우면 쓰던 회의에서 떨어진다** — 참조만 남기면 그 회의는 어떤 필터로도
 * 걸리지 않는다. 그래서 삭제 확인에 "몇 개가 풀리는지" 를 보여준다.
 */
export function TaxonomyPage() {
  const routes = useRoutes();
  const navigate = useNavigate();
  const [topics, setTopics] = useState<Topic[] | null>(null);
  const [labels, setLabels] = useState<Label[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [t, l] = await Promise.all([api.listTopics(), api.listLabels()]);
      setTopics(t.topics);
      setLabels(l.labels);
    } catch (e) {
      setError(e instanceof Error ? e.message : "분류를 불러오지 못했습니다");
      setTopics([]);
      setLabels([]);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <AppShell
      active="archive"
      title="분류 관리"
      subtitle="토픽과 라벨로 회의를 정리합니다"
      onBack={() => navigate(routes.archive)}
    >
      {error && <Notice kind="error" icon="error" className="mb-4">{error}</Notice>}

      {topics === null || labels === null ? (
        <Spinner label="불러오는 중" />
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <Section
            title="토픽"
            hint="회의 하나에 토픽 하나. 순서를 바꿀 수 있습니다."
            items={topics}
            kind="topic"
            nameMax={30}
            onCreate={(body) => api.createTopic(body)}
            onUpdate={(id, body) => api.updateTopic(id, body)}
            onDelete={(id) => api.deleteTopic(id)}
            onMove={async (ids) => {
              const { topics } = await api.reorderTopics(ids);
              setTopics(topics);
            }}
            onChanged={load}
            setError={setError}
          />

          <Section
            title="라벨"
            hint="회의 하나에 라벨 여러 개. 이름순으로 정렬됩니다."
            items={labels}
            kind="label"
            nameMax={20}
            onCreate={(body) => api.createLabel(body)}
            onUpdate={(id, body) => api.updateLabel(id, body)}
            onDelete={(id) => api.deleteLabel(id)}
            onChanged={load}
            setError={setError}
          />
        </div>
      )}
    </AppShell>
  );
}

function Section({
  title,
  hint,
  items,
  kind,
  nameMax,
  onCreate,
  onUpdate,
  onDelete,
  onMove,
  onChanged,
  setError,
}: {
  title: string;
  hint: string;
  items: (Topic | Label)[];
  kind: "topic" | "label";
  nameMax: number;
  onCreate: (body: { name: string; color?: ColorKey }) => Promise<unknown>;
  onUpdate: (id: string, body: { name?: string; color?: ColorKey }) => Promise<unknown>;
  onDelete: (id: string) => Promise<{ detached_meetings: number }>;
  onMove?: (ids: string[]) => Promise<void>;
  onChanged: () => void;
  setError: (message: string | null) => void;
}) {
  const [name, setName] = useState("");
  const [color, setColor] = useState<ColorKey>("blue");
  const [editing, setEditing] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function run(action: () => Promise<unknown>) {
    setBusy(true);
    setError(null);

    try {
      await action();
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : "저장하지 못했습니다");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card>
      <CardBody>
        <h2 style={{ margin: 0, fontSize: 15, fontWeight: 700, color: "var(--text-primary)" }}>
          {title}
        </h2>
        <p className="vr-note" style={{ marginTop: 4, fontSize: 12 }}>{hint}</p>

        <form
          style={{ display: "flex", gap: 6, marginTop: 12, flexWrap: "wrap" }}
          onSubmit={(e) => {
            e.preventDefault();
            const trimmed = name.trim();
            if (!trimmed) return;

            void run(async () => {
              await onCreate({ name: trimmed, color });
              setName("");
            });
          }}
        >
          <input
            className="mobile-field__input"
            data-surface="sunken"
            style={{ flex: 1, minWidth: 140, fontFamily: "var(--font-sans)" }}
            value={name}
            maxLength={nameMax}
            onChange={(e) => setName(e.target.value)}
            placeholder={`${title} 이름`}
            aria-label={`새 ${title} 이름`}
          />
          <ColorPicker value={color} onChange={setColor} />
          <button type="submit" className="mobile-button mobile-button--primary mobile-button--fit" disabled={busy}>
            추가
          </button>
        </form>

        {items.length === 0 ? (
          <EmptyState icon="sell" title={`아직 ${title}이 없습니다`} desc="위에서 추가하세요." />
        ) : (
          <div style={{ display: "flex", flexDirection: "column", marginTop: 12 }}>
            {items.map((item, index) => (
              <div
                key={item.id}
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 8,
                  padding: "8px 0",
                  borderBottom: "var(--hairline-width) solid var(--border-subtle)",
                  flexWrap: "wrap",
                }}
              >
                {editing === item.id ? (
                  <EditRow
                    item={item}
                    nameMax={nameMax}
                    onCancel={() => setEditing(null)}
                    onSave={(body) =>
                      run(async () => {
                        await onUpdate(item.id, body);
                        setEditing(null);
                      })
                    }
                  />
                ) : (
                  <>
                    <Tag item={item} kind={kind} />
                    <span className="mobile-row__meta" style={{ fontSize: 12 }}>
                      회의 {item.meeting_count ?? 0}개
                    </span>

                    <div style={{ marginLeft: "auto", display: "flex", gap: 2 }}>
                      {onMove && (
                        <>
                          <IconButton
                            icon="arrow_upward"
                            label="위로"
                            disabled={index === 0 || busy}
                            onClick={() =>
                              void run(() => onMove(swap(items.map((x) => x.id), index, index - 1)))
                            }
                          />
                          <IconButton
                            icon="arrow_downward"
                            label="아래로"
                            disabled={index === items.length - 1 || busy}
                            onClick={() =>
                              void run(() => onMove(swap(items.map((x) => x.id), index, index + 1)))
                            }
                          />
                        </>
                      )}
                      <IconButton icon="edit" label="고치기" onClick={() => setEditing(item.id)} />
                      <IconButton
                        icon="delete"
                        label="지우기"
                        danger
                        disabled={busy}
                        onClick={() =>
                          void run(async () => {
                            const count = item.meeting_count ?? 0;

                            const ok =
                              count === 0 ||
                              window.confirm(
                                `"${item.name}" 을 지우면 회의 ${count}개에서 이 분류가 떨어집니다. 계속할까요?`,
                              );

                            if (!ok) return;
                            await onDelete(item.id);
                          })
                        }
                      />
                    </div>
                  </>
                )}
              </div>
            ))}
          </div>
        )}
      </CardBody>
    </Card>
  );
}

function EditRow({
  item,
  nameMax,
  onSave,
  onCancel,
}: {
  item: Topic | Label;
  nameMax: number;
  onSave: (body: { name: string; color: ColorKey }) => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState(item.name);
  const [color, setColor] = useState<ColorKey>(item.color);

  return (
    <form
      style={{ display: "flex", gap: 6, flex: 1, flexWrap: "wrap" }}
      onSubmit={(e) => {
        e.preventDefault();
        const trimmed = name.trim();
        if (trimmed) onSave({ name: trimmed, color });
      }}
    >
      <input
        className="mobile-field__input"
        data-surface="sunken"
        style={{ flex: 1, minWidth: 120, fontFamily: "var(--font-sans)" }}
        value={name}
        maxLength={nameMax}
        onChange={(e) => setName(e.target.value)}
        autoFocus
        aria-label="이름"
      />
      <ColorPicker value={color} onChange={setColor} />
      <button type="submit" className="mobile-button mobile-button--primary mobile-button--fit">저장</button>
      <button type="button" className="mobile-button mobile-button--ghost mobile-button--fit" onClick={onCancel}>
        취소
      </button>
    </form>
  );
}

function ColorPicker({
  value,
  onChange,
}: {
  value: ColorKey;
  onChange: (color: ColorKey) => void;
}) {
  return (
    <div style={{ display: "flex", gap: 3, alignItems: "center" }} role="radiogroup" aria-label="색">
      {COLORS.map((key) => (
        <button
          key={key}
          type="button"
          role="radio"
          aria-checked={value === key}
          aria-label={key}
          onClick={() => onChange(key)}
          className="vr-tag"
          data-color={key}
          style={{
            width: 22,
            height: 22,
            padding: 0,
            justifyContent: "center",
            border: 0,
            cursor: "pointer",
            outline: value === key ? "2px solid currentColor" : "none",
            outlineOffset: 1,
          }}
        />
      ))}
    </div>
  );
}

function IconButton({
  icon,
  label,
  onClick,
  disabled,
  danger,
}: {
  icon: string;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  danger?: boolean;
}) {
  return (
    <button
      type="button"
      className="mobile-button mobile-button--ghost mobile-button--fit"
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
      title={label}
      style={danger ? { color: "var(--status-error)" } : undefined}
    >
      <Icon name={icon} />
    </button>
  );
}

function swap(ids: string[], a: number, b: number): string[] {
  const next = [...ids];
  const tmp = next[a]!;
  next[a] = next[b]!;
  next[b] = tmp;
  return next;
}
