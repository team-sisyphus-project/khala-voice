/**
 * **출처: devkanban** `mobile/src/components/StatusChip.tsx` — 그대로 가져왔다.
 *
 * 버튼의 누름 반응 · 헤더 표현 · 인풋 · 모달의 표현 방식을 그대로 쓰기 위해
 * 마크업(클래스 이름)까지 원본과 같게 둔다. CSS 가 이 이름에 걸려 있다.
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
