/**
 * **출처: devkanban** `mobile/src/components/TopAppBar.tsx` — 그대로 가져왔다.
 *
 * 버튼의 누름 반응 · 헤더 표현 · 인풋 · 모달의 표현 방식을 그대로 쓰기 위해
 * 마크업(클래스 이름)까지 원본과 같게 둔다. CSS 가 이 이름에 걸려 있다.
 */

import type { ReactNode } from "react"
import { Icon } from "./Icon"

type TopAppBarProps = {
  title: string
  subtitle?: string
  onBack?: () => void
  onMenu?: () => void
  menuLabel?: string
  action?: ReactNode
  // 제목 옆 인라인 컨트롤(채팅 헤더의 로직 모델 피커). __titles 캡슐은 스크롤
  // 전에는 opacity:0이므로 그 안에 넣으면 첫 화면에서 보이지 않는다 — 항상
  // 보여야 하는 컨트롤은 캡슐 밖 형제로 그린다.
  inlineControl?: ReactNode
  scrolled?: boolean
  // 원본의 `morphTitle`(제목 글자가 흘러 바뀌는 연출)은 가져오지 않았다 —
  // devkanban 채팅 제목 전용이고 이 앱에는 그렇게 바뀌는 제목이 없다.
}

export function TopAppBar({
  title,
  subtitle,
  onBack,
  onMenu,
  menuLabel,
  action,
  inlineControl,
  scrolled = false
}: TopAppBarProps) {
  const className = [
    "mobile-top-app-bar",
    onBack ? "mobile-top-app-bar--detail" : "mobile-top-app-bar--tabs",
    scrolled ? "is-scrolled" : ""
  ]
    .filter(Boolean)
    .join(" ")

  return (
    <header className={className}>
      <div className="mobile-top-app-bar__row">
        {onBack ? (
          <button
            aria-label="Back"
            className="mobile-top-app-bar__icon-button"
            onClick={onBack}
            type="button"
          >
            <Icon name="arrow_back" />
          </button>
        ) : null}
        {onMenu && !onBack ? (
          <button
            aria-label={menuLabel ?? "Menu"}
            className="mobile-top-app-bar__icon-button"
            onClick={onMenu}
            type="button"
          >
            <Icon name="menu" />
          </button>
        ) : null}
        {title || subtitle ? (
          <div className="mobile-top-app-bar__titles">
            {title ? (
              <h1 className="mobile-top-app-bar__title">{title}</h1>
            ) : null}
            {subtitle ? <p className="mobile-top-app-bar__subtitle">{subtitle}</p> : null}
          </div>
        ) : null}
        {inlineControl ? <div className="mobile-top-app-bar__inline">{inlineControl}</div> : null}
        {action ? <div className="mobile-top-app-bar__action">{action}</div> : null}
      </div>
    </header>
  )
}
