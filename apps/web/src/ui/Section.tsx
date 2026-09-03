/**
 * **Source: devkanban** `mobile/src/components/Section.tsx` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
 */

import type { ReactNode } from "react"

type SectionProps = {
  title?: string
  action?: ReactNode
  children: ReactNode
  /**
   * Wraps in a glass card. **An addition** — not in the devkanban original.
   * There, one screen is one flow; here, one screen holds several blocks of
   * different natures, so boundaries need cards to stay readable.
   */
  card?: boolean
  className?: string
}

export function Section({ title, action, children, card = false, className = "" }: SectionProps) {
  return (
    <section
      className={`mobile-section${card ? " mobile-section--card" : ""}${className ? ` ${className}` : ""}`}
    >
      {title || action ? (
        <div className="mobile-section__header">
          {title ? <h2 className="mobile-section__title">{title}</h2> : <span />}
          {action ? <div className="mobile-section__action">{action}</div> : null}
        </div>
      ) : null}
      <div className="mobile-section__body">{children}</div>
    </section>
  )
}
