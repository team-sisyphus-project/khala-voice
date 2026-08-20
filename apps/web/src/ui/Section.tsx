/**
 * **출처: devkanban** `mobile/src/components/Section.tsx` — 그대로 가져왔다.
 *
 * 버튼의 누름 반응 · 헤더 표현 · 인풋 · 모달의 표현 방식을 그대로 쓰기 위해
 * 마크업(클래스 이름)까지 원본과 같게 둔다. CSS 가 이 이름에 걸려 있다.
 */

import type { ReactNode } from "react"

type SectionProps = {
  title?: string
  action?: ReactNode
  children: ReactNode
  /**
   * 유리 카드로 감싼다. **덧붙인 것** — devkanban 원본에는 없다.
   * 그쪽은 한 화면이 한 흐름이지만 이 앱은 한 화면에 성격이 다른 덩어리가
   * 여럿 서기 때문에, 경계를 카드로 끊어야 읽힌다.
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
