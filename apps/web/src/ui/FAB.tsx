/**
 * **출처: devkanban** `mobile/src/components/FAB.tsx` — 그대로 가져왔다.
 *
 * 버튼의 누름 반응 · 헤더 표현 · 인풋 · 모달의 표현 방식을 그대로 쓰기 위해
 * 마크업(클래스 이름)까지 원본과 같게 둔다. CSS 가 이 이름에 걸려 있다.
 */

import { Icon } from "./Icon"

type FABProps = {
  icon: string
  label: string
  onClick: () => void
}

export function FAB({ icon, label, onClick }: FABProps) {
  return (
    <button aria-label={label} className="mobile-fab" onClick={onClick} type="button">
      <Icon name={icon} />
    </button>
  )
}
