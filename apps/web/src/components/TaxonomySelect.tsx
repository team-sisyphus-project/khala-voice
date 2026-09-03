import { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Tag } from "@/components/Tag";
import { Button, Icon, Sheet } from "@/ui";
import type { Label, Topic } from "@core/api";

/**
 * 분류 고르기 — **드롭다운**이지 칩 나열이 아니다.
 *
 * 칩을 전부 펼쳐 두면 토픽이 서른 개가 되는 순간 화면이 칩으로 뒤덮인다.
 * 트리거에는 **고른 것만** 보이고, 고를 때만 목록을 연다.
 *
 * - **토픽은 하나만.** 회의 하나에 토픽 하나가 도메인 규칙이다
 *   (`docs/03-domain-model.md`). 그래서 고르면 바로 닫는다
 * - **라벨은 여럿.** 고르는 동안 열어 두고 [완료]로 닫는다
 * - 목록이 길어질 것을 전제로 **검색**을 늘 둔다
 */

type Item = Topic | Label;

function useSearch<T extends Item>(items: T[], query: string): T[] {
  return useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return items;
    return items.filter((item) => item.name.toLowerCase().includes(q));
  }, [items, query]);
}

/** 고른 것을 보여주는 트리거. 입력칸처럼 생겨서 "여기서 고른다"가 읽힌다. */
function Trigger({
  label,
  empty,
  onClick,
  children,
}: {
  label: string;
  empty: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <div className="vr-filter__group">
      <span className="vr-filter__label">{label}</span>
      <button type="button" className="vr-select" onClick={onClick}>
        <span className="vr-select__value" data-empty={empty ? "true" : undefined}>
          {children}
        </span>
        <Icon name="expand_more" />
      </button>
    </div>
  );
}

export function TopicSelect({
  topics,
  value,
  onChange,
  onCreate,
}: {
  topics: Topic[];
  value: string | null;
  /** null 이면 토픽 없음 */
  onChange: (topicId: string | null) => void;
  /** 새 토픽을 만들고 그 id 를 돌려준다. 없으면 만들기 줄을 숨긴다 */
  onCreate?: (name: string) => Promise<Topic | null>;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [creating, setCreating] = useState(false);

  const shown = useSearch(topics, query);
  const picked = topics.find((t) => t.id === value) ?? null;

  // 같은 이름이 이미 있으면 만들기 줄을 띄우지 않는다 — 중복 토픽이 늘어난다
  const typed = query.trim();
  const canCreate =
    Boolean(onCreate) &&
    typed.length > 0 &&
    !topics.some((t) => t.name.trim().toLowerCase() === typed.toLowerCase());

  async function create() {
    if (!onCreate) return;

    setCreating(true);

    try {
      const topic = await onCreate(typed);
      if (topic) {
        onChange(topic.id);
        setQuery("");
        setOpen(false);
      }
    } finally {
      setCreating(false);
    }
  }

  return (
    <>
      <Trigger label={t("taxonomySelect.topic")} empty={!picked} onClick={() => setOpen(true)}>
        {picked ? <Tag item={picked} kind="topic" /> : t("taxonomySelect.none")}
      </Trigger>

      {open && (
        <Sheet title={t("taxonomySelect.topic")} onClose={() => setOpen(false)}>
          <div className="vr-filter">
            <input
              className="mobile-field__input"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder={onCreate ? t("taxonomySelect.searchOrCreate") : t("taxonomySelect.findTopic")}
              aria-label={t("taxonomySelect.findTopic")}
              autoFocus
            />

            <div className="vr-options">
              <button
                type="button"
                className="vr-options__item"
                data-active={value === null}
                onClick={() => {
                  onChange(null);
                  setOpen(false);
                }}
              >
                <span className="vr-options__name">{t("taxonomySelect.none")}</span>
                {value === null && <Icon name="check" />}
              </button>

              {shown.map((topic) => (
                <button
                  key={topic.id}
                  type="button"
                  className="vr-options__item"
                  data-active={value === topic.id}
                  onClick={() => {
                    // 토픽은 하나뿐이라 고르는 즉시 끝난다
                    onChange(topic.id);
                    setOpen(false);
                  }}
                >
                  <Tag item={topic} kind="topic" />
                  {value === topic.id && <Icon name="check" />}
                </button>
              ))}

              {shown.length === 0 && !canCreate && (
                <p className="vr-note vr-note--small">{t("taxonomySelect.noTopicFound")}</p>
              )}
            </div>

            {canCreate && (
              <Button icon="add" full onClick={() => void create()} pending={creating} loadingLabel={t("taxonomySelect.creating")}>
                {t("taxonomySelect.createTopicNamed", { name: typed })}
              </Button>
            )}
          </div>
        </Sheet>
      )}
    </>
  );
}

export function LabelSelect({
  labels,
  value,
  onChange,
}: {
  labels: Label[];
  value: string[];
  onChange: (labelIds: string[]) => void;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");

  const shown = useSearch(labels, query);
  const picked = labels.filter((l) => value.includes(l.id));

  function toggle(id: string) {
    onChange(value.includes(id) ? value.filter((x) => x !== id) : [...value, id]);
  }

  return (
    <>
      <Trigger label={t("taxonomySelect.label")} empty={picked.length === 0} onClick={() => setOpen(true)}>
        {picked.length > 0 ? picked.map((l) => <Tag key={l.id} item={l} />) : t("taxonomySelect.none")}
      </Trigger>

      {open && (
        <Sheet title={t("taxonomySelect.label")} onClose={() => setOpen(false)}>
          <div className="vr-filter">
            <input
              className="mobile-field__input"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder={t("taxonomySelect.findLabel")}
              aria-label={t("taxonomySelect.findLabel")}
              autoFocus
            />

            <div className="vr-options">
              {shown.map((label) => {
                const on = value.includes(label.id);

                return (
                  <button
                    key={label.id}
                    type="button"
                    className="vr-options__item"
                    data-active={on}
                    onClick={() => toggle(label.id)}
                  >
                    <Tag item={label} />
                    {on && <Icon name="check" />}
                  </button>
                );
              })}

              {shown.length === 0 && (
                <p className="vr-note vr-note--small">
                  {labels.length === 0
                    ? t("taxonomySelect.noLabelsYet")
                    : t("taxonomySelect.noLabelFound")}
                </p>
              )}
            </div>

            {/* 라벨은 여러 개를 고르는 동안 열어 둔다 */}
            <Button full onClick={() => setOpen(false)}>
              {t("taxonomySelect.done")}
            </Button>
          </div>
        </Sheet>
      )}
    </>
  );
}
