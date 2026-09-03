/**
 * **Source: devkanban** `mobile/src/components/StatusChip.tsx` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
 */

export type StatusTone =
  | "todo"
  | "planned"
  | "in-progress"
  | "in-review"
  | "done"
  | "cancelled"
  | "waiting"
  | "neutral"

const TONE_BY_STATUS: Record<string, StatusTone> = {
  todo: "todo",
  planned: "planned",
  in_progress: "in-progress",
  running: "in-progress",
  in_review: "in-review",
  review_needed: "in-review",
  done: "done",
  completed: "done",
  cancelled: "cancelled",
  waiting_on_me: "waiting",
  waiting: "waiting"
}

export function statusTone(status: string): StatusTone {
  return TONE_BY_STATUS[status.toLowerCase()] ?? "neutral"
}

export function StatusChip({ status, label }: { status: string; label: string }) {
  const tone = statusTone(status)
  const pulse = tone === "in-progress"

  return (
    <span className={`mobile-status-chip mobile-status-chip--${tone}`}>
      {pulse ? <span className="mobile-status-chip__dot" aria-hidden="true" /> : null}
      {label}
    </span>
  )
}
