/**
 * 알림 띠.
 *
 * **출처: devkanban** `mobile/src/components/InlineFailure.tsx` 의 마크업 문법
 * (`mobile-inline-failure`)을 확장했다. 원본은 오류 하나만 다루지만 이 앱은
 * 경고·안내·완료도 같은 자리에서 말해야 해서 색만 tone 으로 나눈다.
 *
 * 색은 devkanban 토큰을 그대로 쓴다 — 새로 만들지 않는다.
 */
import type { ReactNode } from "react"
import { Icon } from "./Icon"

export type NoticeTone = "info" | "warn" | "error" | "ok"

const TONE_ICON: Record<NoticeTone, string> = {
  info: "info",
  warn: "warning",
  error: "error",
  ok: "check_circle",
}

export function Notice({
  tone = "info",
  title,
  icon,
  action,
  children,
}: {
  tone?: NoticeTone
  title?: string
  icon?: string
  action?: ReactNode
  children?: ReactNode
}) {
  return (
    <div className="mobile-inline-failure" data-tone={tone} role={tone === "error" ? "alert" : "status"}>
      <span className="mobile-inline-failure__icon" aria-hidden="true">
        <Icon name={icon ?? TONE_ICON[tone]} />
      </span>

      <div className="mobile-inline-failure__body">
        {title ? <strong className="mobile-inline-failure__title">{title}</strong> : null}
        {children ? <span className="mobile-inline-failure__message">{children}</span> : null}
      </div>

      {action ? <div className="mobile-inline-failure__actions">{action}</div> : null}
    </div>
  )
}
