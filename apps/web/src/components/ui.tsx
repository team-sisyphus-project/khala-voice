import type { ReactNode } from "react";
import i18n from "@/i18n";
import { EmptyState as DkEmptyState, Notice as DkNotice, StatusChip } from "@/ui";
import type { NoticeTone } from "@/ui";

/**
 * A thin layer bridging the old shared UI to devkanban widgets.
 *
 * Screens use `Card` / `Notice` / `Chip` all over, so instead of fixing
 * everything at once, **the devkanban markup is swapped in here.** Migrating
 * screens one by one and stopping midway would mix two designs in one app —
 * worse.
 *
 * New screens use `@/ui` directly, not this file. What's here is a bridge for
 * the migration.
 */

/**
 * devkanban has no Card. A glass-card variant over `mobile-section` fills the
 * same role. Without card boundaries, a screen's chunks read as one blob.
 */
export function Card({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <section className={`mobile-section mobile-section--card ${className}`}>{children}</section>;
}

export function CardBody({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <div className={`mobile-section__body ${className}`}>{children}</div>;
}

export function Notice({
  kind = "info",
  icon,
  title,
  children,
  className = "",
}: {
  kind?: NoticeTone;
  icon?: string;
  title?: string;
  children?: ReactNode;
  className?: string;
}) {
  // className carries old spacing utils (mb-4 etc.), passed through — new layouts use gap
  void className;

  return (
    <DkNotice tone={kind} title={title} icon={icon}>
      {children}
    </DkNotice>
  );
}

const CHIP_STATUS: Record<string, string> = {
  ok: "done",
  info: "in-progress",
  warn: "waiting",
  error: "cancelled",
  neutral: "neutral",
};

export function Chip({
  kind = "neutral",
  children,
}: {
  kind?: "ok" | "info" | "warn" | "error" | "neutral";
  children: ReactNode;
}) {
  return <StatusChip status={CHIP_STATUS[kind] ?? "neutral"} label={String(children)} />;
}

export function EmptyState({
  icon,
  title,
  desc,
  children,
}: {
  icon?: string;
  title: string;
  desc?: string;
  children?: ReactNode;
}) {
  void icon;

  return (
    <>
      <DkEmptyState title={title} description={desc} />
      {children}
    </>
  );
}

/** Loading speaks through empty-state copy, no separate treatment — devkanban grammar. */
export function Spinner({ label }: { label?: string }) {
  return <DkEmptyState title={label ?? i18n.t("common.loading")} />;
}

export function Avatar({ id, name, size = 32 }: { id: string; name?: string | null; size?: number }) {
  const letter = (name || id).trim().charAt(0).toUpperCase();

  // The same person must always get the same color. Fold the id into a color.
  const hue = [...id].reduce((acc, ch) => (acc * 31 + ch.charCodeAt(0)) % 360, 7);

  return (
    <span
      aria-hidden="true"
      style={{
        width: size,
        height: size,
        borderRadius: "var(--mobile-radius-full)",
        display: "grid",
        placeItems: "center",
        flexShrink: 0,
        fontSize: size * 0.42,
        fontWeight: 700,
        color: "#fff",
        background: `oklch(62% 0.13 ${hue})`,
      }}
    >
      {letter}
    </span>
  );
}
