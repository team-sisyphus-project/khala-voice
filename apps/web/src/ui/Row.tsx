/**
 * **Source: devkanban** `mobile/src/components/Row.tsx` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
 */

import type { ReactNode } from "react"
import { Icon } from "./Icon"

type RowProps = {
  icon?: string
  avatar?: string
  title: ReactNode
  meta?: ReactNode
  trailing?: ReactNode
  chevron?: boolean
  onClick?: () => void
}

export function Row({ icon, avatar, title, meta, trailing, chevron = false, onClick }: RowProps) {
  const interactive = Boolean(onClick)
  const className = interactive ? "mobile-row mobile-row--interactive" : "mobile-row"
  const content = (
    <>
      {avatar ? (
        <span className="mobile-row__avatar" aria-hidden="true">
          {avatar}
        </span>
      ) : icon ? (
        <span className="mobile-row__icon" aria-hidden="true">
          <Icon name={icon} />
        </span>
      ) : null}
      <span className="mobile-row__main">
        <span className="mobile-row__title">{title}</span>
        {meta ? <span className="mobile-row__meta">{meta}</span> : null}
      </span>
      {trailing ? <span className="mobile-row__trailing">{trailing}</span> : null}
      {chevron ? (
        <span className="mobile-row__chevron" aria-hidden="true">
          <Icon name="chevron_right" />
        </span>
      ) : null}
    </>
  )

  if (interactive) {
    return (
      <button className={className} onClick={onClick} type="button">
        {content}
      </button>
    )
  }

  return <div className={className}>{content}</div>
}
