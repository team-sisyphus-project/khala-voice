/**
 * Bottom-sheet modal.
 *
 * **Source: devkanban** — `BoardSheet` from
 * `mobile/src/screens/BoardSettingsSheet.tsx`. Uses the markup
 * (`mobile-context-sheet` class) as-is — the CSS is keyed to the name.
 *
 * Difference from the original: besides pressing the scrim, **Esc also
 * closes it** — this app uses the same screens on desktop too.
 */
import { useEffect } from "react"
import { useTranslation } from "react-i18next"
import type { ReactNode } from "react"
import { Icon } from "./Icon"

type SheetProps = {
  title: string
  onClose: () => void
  children: ReactNode
}

export function Sheet({ title, onClose, children }: SheetProps) {
  const { t } = useTranslation()

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose()
    }

    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [onClose])

  return (
    <div aria-label={title} aria-modal="true" className="mobile-context-sheet" role="dialog">
      <button aria-label={t("common.close")} className="mobile-context-sheet__scrim" onClick={onClose} type="button" />
      <div className="mobile-context-sheet__panel">
        <span aria-hidden="true" className="mobile-context-sheet__grabber" />
        <div className="mobile-context-sheet__head">
          <h2 className="mobile-context-sheet__title">{title}</h2>
          <div className="mobile-context-sheet__head-actions">
            <button
              aria-label={t("common.close")}
              className="mobile-context-sheet__head-button"
              onClick={onClose}
              type="button"
            >
              <Icon name="close" />
            </button>
          </div>
        </div>
        {children}
      </div>
    </div>
  )
}
