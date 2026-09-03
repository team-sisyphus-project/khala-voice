import type { ReactNode } from "react";
import i18n from "@/i18n";
import { EmptyState as DkEmptyState, Notice as DkNotice, StatusChip } from "@/ui";
import type { NoticeTone } from "@/ui";

/**
 * 옛 공용 UI 를 devkanban 위젯으로 잇는 얇은 층.
 *
 * 화면들이 `Card` / `Notice` / `Chip` 을 곳곳에서 쓰고 있어서, 한 번에 다 고치는
 * 대신 **여기서 devkanban 마크업으로 갈아끼운다.** 화면을 하나씩 옮기다 말면
 * 같은 앱 안에 두 디자인이 섞여 더 나빠진다.
 *
 * 새 화면은 이 파일이 아니라 `@/ui` 를 직접 쓴다. 여기 있는 것은 옮겨가는 동안의 다리다.
 */

/**
 * devkanban 에는 Card 가 없다. `mobile-section` 에 유리 카드 변형을 씌워 같은 자리를 맡긴다.
 * 카드 경계가 없으면 한 화면의 덩어리들이 한 덩어리로 읽힌다.
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
  // className 은 옛 여백 유틸(mb-4 등)이라 흘려보낸다 — 새 레이아웃은 gap 이 맡는다
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

/** 로딩은 별도 연출 없이 빈 상태 문구로 말한다 — devkanban 문법이다. */
export function Spinner({ label }: { label?: string }) {
  return <DkEmptyState title={label ?? i18n.t("common.loading")} />;
}

export function Avatar({ id, name, size = 32 }: { id: string; name?: string | null; size?: number }) {
  const letter = (name || id).trim().charAt(0).toUpperCase();

  // 같은 사람은 늘 같은 색이어야 한다. id 를 색으로 접는다.
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
