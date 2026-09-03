/**
 * The body's large title.
 *
 * **Source: devkanban** — the `mobile-page-header` markup.
 *
 * ## Why the title lives in the body
 *
 * On tab screens the top bar hides its title until scrolled
 * (`mobile-top-app-bar--tabs`). The large title sits at the top of the body,
 * and when it scrolls away the top bar takes over.
 * **So the title must never be drawn in two places** — the same text would
 * appear stacked above and below.
 */
import type { ReactNode } from "react"

export function PageHeader({
  title,
  subtitle,
  action,
}: {
  title: string
  subtitle?: string
  action?: ReactNode
}) {
  return (
    <header className={action ? "mobile-page-header mobile-page-header--row" : "mobile-page-header"}>
      <div style={{ minWidth: 0 }}>
        <h1 className="mobile-page-header__title">{title}</h1>
        {subtitle ? <p className="mobile-page-header__subtitle">{subtitle}</p> : null}
      </div>
      {action ?? null}
    </header>
  )
}
