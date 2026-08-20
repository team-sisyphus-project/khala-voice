import type { Label, Topic } from "@core/api";

/**
 * 토픽 · 라벨 칩.
 *
 * **출처: sisyphus** 의 라벨 칩. 색은 자유 HEX 가 아니라 **팔레트 키**다 —
 * 테마가 넷(light · dark · pencil · game)이라 사용자가 고른 임의 색이
 * 네 배경 모두에서 읽힌다는 보장이 없다. 키를 실제 색으로 바꾸는 것은 CSS 가 한다.
 *
 * 삭제된 분류도 그린다. 아직 회의에 참조가 남아 있는데 이름 없이 그리면
 * 화면에 정체불명의 칩이 뜬다.
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

/** 회의 카드에 붙는 분류 묶음. 없으면 아무것도 그리지 않는다. */
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
