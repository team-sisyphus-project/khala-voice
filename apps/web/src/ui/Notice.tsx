/**
 * Notice strip.
 *
 * **Source: devkanban** — extends the markup grammar of
 * `mobile/src/components/InlineFailure.tsx` (`mobile-inline-failure`). The
 * original only handles errors, but this app must also speak warnings, info,
 * and success in the same spot, so only the color splits by tone.
 *
 * Colors use devkanban tokens as-is — none invented.
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
