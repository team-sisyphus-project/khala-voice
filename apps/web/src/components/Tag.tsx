import type { Label, Topic } from "@core/api";

/**
 * Topic and label chips.
 *
 * **Source: sisyphus** — its label chips. Colors are **palette keys**, not
 * free-form HEX — with four themes (light · dark · pencil · game), an
 * arbitrary user-picked color has no guarantee of reading on all four
 * backgrounds. CSS turns keys into actual colors.
 *
 * Deleted taxonomy still renders. Meetings may still reference it, and
 * rendering without a name puts an unidentifiable chip on screen.
 */
export function Tag({
  item,
  kind = "label",
  onClick,
  pressed,
}: {
  item: Topic | Label;
  kind?: "topic" | "label";
  onClick?: () => void;
  pressed?: boolean;
}) {
  const className = [
    "vr-tag",
    kind === "topic" && "vr-tag--topic",
    onClick && "vr-filter__chip",
  ]
    .filter(Boolean)
    .join(" ");

  const content = (
    <>
      {item.name}
      {typeof item.meeting_count === "number" && (
        <span style={{ opacity: 0.7, fontWeight: 400 }}>{item.meeting_count}</span>
      )}
    </>
  );

  if (!onClick) {
    return (
      <span className={className} data-color={item.color} data-deleted={item.deleted || undefined}>
        {content}
      </span>
    );
  }

  return (
    <button
      type="button"
      className={className}
      data-color={item.color}
      data-deleted={item.deleted || undefined}
      aria-pressed={pressed ?? false}
      onClick={onClick}
    >
      {content}
    </button>
  );
}

/** The taxonomy cluster on a meeting card. Renders nothing when empty. */
export function TagRow({ topic, labels }: { topic?: Topic | null; labels?: Label[] }) {
  const items = labels ?? [];
  if (!topic && items.length === 0) return null;

  return (
    <div style={{ display: "flex", gap: 5, flexWrap: "wrap", marginTop: 8 }}>
      {topic && <Tag item={topic} kind="topic" />}
      {items.map((label) => (
        <Tag key={label.id} item={label} />
      ))}
    </div>
  );
}
