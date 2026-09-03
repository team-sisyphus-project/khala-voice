import i18n from "@/i18n";

/** H:MM:SS. Used for both the timer and segment timestamps. */
export function formatDuration(seconds: number | null | undefined): string {
  const total = Math.max(0, Math.floor(seconds ?? 0));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

export function formatBytes(bytes: number | null | undefined): string {
  if (!bytes) return "-";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export function formatRelative(iso: string | null | undefined): string {
  if (!iso) return "-";

  const date = new Date(iso);
  const diff = Math.floor((Date.now() - date.getTime()) / 1000);

  if (diff < 60) return i18n.t("time.justNow");
  if (diff < 3600) return i18n.t("time.minutesAgo", { count: Math.floor(diff / 60) });
  if (diff < 86_400) return i18n.t("time.hoursAgo", { count: Math.floor(diff / 3600) });
  if (diff < 7 * 86_400) return i18n.t("time.daysAgo", { count: Math.floor(diff / 86_400) });

  return date.toLocaleDateString(i18n.language, { year: "numeric", month: "long", day: "numeric" });
}

export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return "-";
  return new Date(iso).toLocaleString(i18n.language, {
    year: "numeric",
    month: "long",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}
