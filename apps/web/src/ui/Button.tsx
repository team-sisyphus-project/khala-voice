/**
 * **출처: devkanban** `mobile/src/components/Button.tsx` — 그대로 가져왔다.
 *
 * 버튼의 누름 반응 · 헤더 표현 · 인풋 · 모달의 표현 방식을 그대로 쓰기 위해
 * 마크업(클래스 이름)까지 원본과 같게 둔다. CSS 가 이 이름에 걸려 있다.
 */

import type { ReactNode } from "react"
import { Icon } from "./Icon"

type ButtonVariant = "primary" | "secondary" | "danger" | "ghost"

type ButtonProps = {
  children?: ReactNode
  variant?: ButtonVariant
  icon?: string
  trailingIcon?: string
  full?: boolean
  // 본문 안 버튼은 섹션 flex-column의 stretch를 받지 않고 내용 너비만 차지한다.
  fit?: boolean
  square?: boolean
  // square와 함께 쓰면 원형 버튼(라운드 사각 대신). 예: 이슈카드 상세의 채팅 버튼.
  round?: boolean
  disabled?: boolean
  pending?: boolean
  loadingLabel?: string
  // 면 전체 선형 프로그레스 — variant와 직교하는 옵션이다. 켜면 버튼 배경이
  // progress(0~1)만큼 왼쪽부터 채워지듯 물들고(프라이머리는 색이 진해지는
  // 방향), 남은 초를 라벨 우측에 숫자로 보여준다. "가만히 있으면 이게 된다"를
  // 버튼 자체로 알리는 카운트다운 문법(음성 동의 기본값 승인, 2026-07-30).
  fillProgress?: number | null
  fillSeconds?: number | null
  type?: "button" | "submit"
  onClick?: () => void
}

export function Button({
  children,
  variant = "primary",
  icon,
  trailingIcon,
  full = false,
  fit = false,
  square = false,
  round = false,
  disabled = false,
  pending = false,
  loadingLabel,
  fillProgress = null,
  fillSeconds = null,
  type = "button",
  onClick
}: ButtonProps) {
  const classes = ["mobile-button", `mobile-button--${variant}`]

  if (full) classes.push("mobile-button--full")
  if (fit) classes.push("mobile-button--fit")
  if (square) classes.push("mobile-button--square")
  if (round) classes.push("mobile-button--round")
  if (pending) classes.push("mobile-button--pending")

  const filling = typeof fillProgress === "number"

  if (filling) classes.push("mobile-button--filling")

  return (
    <button
      className={classes.join(" ")}
      disabled={disabled || pending}
      onClick={onClick}
      type={type}
    >
      {filling ? (
        // 채움 층은 콘텐츠 아래에 절대배치로 깔린다 — 텍스트·아이콘은 그대로
        // 두고 배경만 왼쪽부터 차오른다. width 전환은 틱 간격만큼만 부드럽게.
        <span
          aria-hidden="true"
          className="mobile-button__fill"
          style={{ width: `${Math.min(Math.max(fillProgress, 0), 1) * 100}%` }}
        />
      ) : null}
      {icon ? <Icon name={icon} /> : null}
      {pending && loadingLabel ? (
        <span>{loadingLabel}</span>
      ) : children ? (
        <span>{children}</span>
      ) : null}
      {filling && typeof fillSeconds === "number" ? (
        <span className="mobile-button__fill-seconds">{fillSeconds}</span>
      ) : null}
      {trailingIcon ? <Icon name={trailingIcon} /> : null}
    </button>
  )
}
