/**
 * **출처: devkanban** `mobile/src/components/EmptyState.tsx` — 그대로 가져왔다.
 *
 * 버튼의 누름 반응 · 헤더 표현 · 인풋 · 모달의 표현 방식을 그대로 쓰기 위해
 * 마크업(클래스 이름)까지 원본과 같게 둔다. CSS 가 이 이름에 걸려 있다.
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
