/**
 * **Source: devkanban** `mobile/src/components/Button.tsx` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
 */

import type { ReactNode } from "react"
import { Icon } from "./Icon"

type ButtonVariant = "primary" | "secondary" | "danger" | "ghost"

type ButtonProps = {
  children?: ReactNode
  variant?: ButtonVariant
  icon?: string
  trailingIcon?: string
  full?: boolean
  // In-body buttons don't take the section flex-column's stretch; they only span their content width.
  fit?: boolean
  square?: boolean
  // Combined with square, makes a circular button (instead of a rounded square). E.g. the chat button on the issue-card detail.
  round?: boolean
  disabled?: boolean
  pending?: boolean
  loadingLabel?: string
  // Full-face linear progress — an option orthogonal to variant. When on, the
  // button background tints as if filling from the left by progress (0–1)
  // (primary deepens in color), with remaining seconds shown as a number right
  // of the label. A countdown grammar where the button itself says "do nothing
  // and this happens" (voice-consent default approval, 2026-07-30).
  fillProgress?: number | null
  fillSeconds?: number | null
  type?: "button" | "submit"
  onClick?: () => void
}

export function Button({
  children,
  variant = "primary",
  icon,
  trailingIcon,
  full = false,
  fit = false,
  square = false,
  round = false,
  disabled = false,
  pending = false,
  loadingLabel,
  fillProgress = null,
  fillSeconds = null,
  type = "button",
  onClick
}: ButtonProps) {
  const classes = ["mobile-button", `mobile-button--${variant}`]

  if (full) classes.push("mobile-button--full")
  if (fit) classes.push("mobile-button--fit")
  if (square) classes.push("mobile-button--square")
  if (round) classes.push("mobile-button--round")
  if (pending) classes.push("mobile-button--pending")

  const filling = typeof fillProgress === "number"

  if (filling) classes.push("mobile-button--filling")

  return (
    <button
      className={classes.join(" ")}
      disabled={disabled || pending}
      onClick={onClick}
      type={type}
    >
      {filling ? (
        // The fill layer sits absolutely positioned under the content — text and
        // icons stay put while only the background fills from the left. The width
        // transition is smoothed only across one tick interval.
        <span
          aria-hidden="true"
          className="mobile-button__fill"
          style={{ width: `${Math.min(Math.max(fillProgress, 0), 1) * 100}%` }}
        />
      ) : null}
      {icon ? <Icon name={icon} /> : null}
      {pending && loadingLabel ? (
        <span>{loadingLabel}</span>
      ) : children ? (
        <span>{children}</span>
      ) : null}
      {filling && typeof fillSeconds === "number" ? (
        <span className="mobile-button__fill-seconds">{fillSeconds}</span>
      ) : null}
      {trailingIcon ? <Icon name={trailingIcon} /> : null}
    </button>
  )
}
