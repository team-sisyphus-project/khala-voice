/**
 * 상단바의 **동그란 글래스 버튼**.
 *
 * **출처: devkanban** — `mobile-top-app-bar__icon-button` 클래스와 그 CSS 를 그대로 쓴다.
 * devkanban 은 TopAppBar 안에서만 이 마크업을 인라인으로 썼는데, 이 앱은 화면마다
 * 상단 액션이 달라 컴포넌트로 뽑았다. **모양은 원본과 같다.**
 *
 * 상단 액션은 아이콘만 둔다. 아이콘+글자 버튼을 얹으면 캡슐 제목과 무게가 같아져
 * 상단이 두 덩어리로 읽힌다.
 */

import { Icon } from "./Icon"

type IconButtonProps = {
  icon: string
  label: string
  onClick?: () => void
  disabled?: boolean
  /** 켜짐 상태 (필터가 걸려 있다 등) */
  active?: boolean
  type?: "button" | "submit"
}

export function IconButton({
  icon,
  label,
  onClick,
  disabled = false,
  active = false,
  type = "button"
}: IconButtonProps) {
  return (
    <button
      aria-label={label}
      aria-pressed={active ? true : undefined}
      className="mobile-top-app-bar__icon-button"
      data-active={active ? "true" : undefined}
      disabled={disabled}
      onClick={onClick}
      title={label}
      type={type}
    >
      <Icon name={icon} />
    </button>
  )
}
