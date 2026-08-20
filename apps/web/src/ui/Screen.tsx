/**
 * **출처: devkanban** `mobile/src/components/Screen.tsx` — 그대로 가져왔다.
 *
 * 버튼의 누름 반응 · 헤더 표현 · 인풋 · 모달의 표현 방식을 그대로 쓰기 위해
 * 마크업(클래스 이름)까지 원본과 같게 둔다. CSS 가 이 이름에 걸려 있다.
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
