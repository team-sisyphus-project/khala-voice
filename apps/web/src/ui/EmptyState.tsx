/**
 * **Source: devkanban** `mobile/src/components/EmptyState.tsx` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
 */

import type { ReactNode } from "react"

export function EmptyState({ title, description }: { title: string; description?: ReactNode }) {
  return (
    <div className="mobile-empty-state">
      <p className="mobile-empty-state__title">{title}</p>
      {description ? <p className="mobile-empty-state__description">{description}</p> : null}
    </div>
  )
}
