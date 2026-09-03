/**
 * **Source: devkanban** `mobile/src/components/TopAppBar.tsx` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
 */

import type { ReactNode } from "react"
import { Icon } from "./Icon"

type TopAppBarProps = {
  title: string
  subtitle?: string
  onBack?: () => void
  onMenu?: () => void
  menuLabel?: string
  action?: ReactNode
  // The inline control beside the title (the logic-model picker in the chat
  // header). The __titles capsule is opacity:0 before scrolling, so anything
  // inside it is invisible on the first screen — controls that must always
  // show are drawn as siblings outside the capsule.
  inlineControl?: ReactNode
  scrolled?: boolean
  // The original's `morphTitle` (the flowing title-change effect) wasn't
  // brought over — it's specific to devkanban chat titles, and no title in
  // this app changes that way.
}

export function TopAppBar({
  title,
  subtitle,
  onBack,
  onMenu,
  menuLabel,
  action,
  inlineControl,
  scrolled = false
}: TopAppBarProps) {
  const className = [
    "mobile-top-app-bar",
    onBack ? "mobile-top-app-bar--detail" : "mobile-top-app-bar--tabs",
    scrolled ? "is-scrolled" : ""
  ]
    .filter(Boolean)
    .join(" ")

  return (
    <header className={className}>
      <div className="mobile-top-app-bar__row">
        {onBack ? (
          <button
            aria-label="Back"
            className="mobile-top-app-bar__icon-button"
            onClick={onBack}
            type="button"
          >
            <Icon name="arrow_back" />
          </button>
        ) : null}
        {onMenu && !onBack ? (
          <button
            aria-label={menuLabel ?? "Menu"}
            className="mobile-top-app-bar__icon-button"
            onClick={onMenu}
            type="button"
          >
            <Icon name="menu" />
          </button>
        ) : null}
        {title || subtitle ? (
          <div className="mobile-top-app-bar__titles">
            {title ? (
              <h1 className="mobile-top-app-bar__title">{title}</h1>
            ) : null}
            {subtitle ? <p className="mobile-top-app-bar__subtitle">{subtitle}</p> : null}
          </div>
        ) : null}
        {inlineControl ? <div className="mobile-top-app-bar__inline">{inlineControl}</div> : null}
        {action ? <div className="mobile-top-app-bar__action">{action}</div> : null}
      </div>
    </header>
  )
}
