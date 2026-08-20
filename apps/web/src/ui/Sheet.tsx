/**
 * 바텀시트 모달.
 *
 * **출처: devkanban** `mobile/src/screens/BoardSettingsSheet.tsx` 의 `BoardSheet`.
 * 마크업(`mobile-context-sheet` 클래스)을 그대로 쓴다 — CSS 가 이 이름에 걸려 있다.
 *
 * 원본과 다른 점: 스크림을 눌러 닫는 것 외에 **Esc 로도 닫는다.**
 * 이 앱은 데스크톱에서도 같은 화면을 쓰기 때문이다.
 */
import { useEffect } from "react"
import type { ReactNode } from "react"
import { Icon } from "./Icon"

type SheetProps = {
  title: string
  onClose: () => void
  children: ReactNode
}

export function Sheet({ title, onClose, children }: SheetProps) {
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose()
    }

    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [onClose])

  return (
    <div aria-label={title} aria-modal="true" className="mobile-context-sheet" role="dialog">
      <button aria-label="닫기" className="mobile-context-sheet__scrim" onClick={onClose} type="button" />
      <div className="mobile-context-sheet__panel">
        <span aria-hidden="true" className="mobile-context-sheet__grabber" />
        <div className="mobile-context-sheet__head">
          <h2 className="mobile-context-sheet__title">{title}</h2>
          <div className="mobile-context-sheet__head-actions">
            <button
              aria-label="닫기"
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
