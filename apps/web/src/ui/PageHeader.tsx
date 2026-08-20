/**
 * 본문 큰 제목.
 *
 * **출처: devkanban** `mobile-page-header` 마크업.
 *
 * ## 제목은 왜 본문에 있나
 *
 * 탭 화면의 상단바는 스크롤하기 전까지 제목을 숨긴다 (`mobile-top-app-bar--tabs`).
 * 큰 제목은 본문 맨 위에 있고, 스크롤해서 그것이 사라질 때 상단바가 이어받는다.
 * **그래서 제목을 두 곳에 그리면 안 된다** — 같은 글자가 위아래로 겹쳐 보인다.
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
