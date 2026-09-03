/**
 * **Source: devkanban** `mobile/src/components/Screen.tsx` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
 */

import type { ReactNode, Ref } from "react"

type ScreenProps = {
  children: ReactNode
  center?: boolean
  padBottom?: number
  scrollRef?: Ref<HTMLDivElement>
}

export function Screen({ children, center = false, padBottom, scrollRef }: ScreenProps) {
  const style = padBottom
    ? { paddingBottom: `calc(var(--mobile-content-pad-bottom) + ${padBottom}px)` }
    : undefined

  return (
    <div
      className={center ? "mobile-screen mobile-screen--center" : "mobile-screen"}
      ref={scrollRef}
      style={style}
    >
      <div className="mobile-screen__inner">{children}</div>
    </div>
  )
}
