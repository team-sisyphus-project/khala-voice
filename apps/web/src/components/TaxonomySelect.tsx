import { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Tag } from "@/components/Tag";
import { Button, Icon, Sheet } from "@/ui";
import type { Label, Topic } from "@core/api";

/**
 * Taxonomy picking — a **dropdown**, not a spread of chips.
 *
 * With every chip laid out, the screen drowns in chips the moment there are
 * thirty topics. The trigger shows **only what's picked**; the list opens only
 * while picking.
 *
 * - **One topic only.** One topic per meeting is the domain rule
 *   (`docs/03-domain-model.md`), so picking closes immediately
 * - **Labels are many.** Stays open while picking; [Done] closes it
 * - **Search** is always present, assuming the list will grow long
 */

type Item = Topic | Label;

function useSearch<T extends Item>(items: T[], query: string): T[] {
  return useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return items;
    return items.filter((item) => item.name.toLowerCase().includes(q));
  }, [items, query]);
}

/** The trigger showing what's picked. Shaped like an input, so it reads as "pick here". */
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
  /** null means no topic */
  onChange: (topicId: string | null) => void;
  /** Create a new topic and return its id. If absent, the create row is hidden */
  onCreate?: (name: string) => Promise<Topic | null>;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [creating, setCreating] = useState(false);

  const shown = useSearch(topics, query);
  const picked = topics.find((t) => t.id === value) ?? null;

  // If the same name already exists, don't show the create row — duplicate topics pile up
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
                    // There's only one topic, so picking finishes immediately
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

            {/* Labels stay open while picking multiple */}
            <Button full onClick={() => setOpen(false)}>
              {t("taxonomySelect.done")}
            </Button>
          </div>
        </Sheet>
      )}
    </>
  );
}
