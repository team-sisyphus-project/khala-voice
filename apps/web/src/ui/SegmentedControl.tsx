/**
 * **출처: devkanban** `mobile/src/components/SegmentedControl.tsx` — 그대로 가져왔다.
 *
 * 버튼의 누름 반응 · 헤더 표현 · 인풋 · 모달의 표현 방식을 그대로 쓰기 위해
 * 마크업(클래스 이름)까지 원본과 같게 둔다. CSS 가 이 이름에 걸려 있다.
 */

type SegmentOption<T extends string> = {
  value: T
  label: string
}

type SegmentedControlProps<T extends string> = {
  options: SegmentOption<T>[]
  value: T
  onChange: (value: T) => void
}

export function SegmentedControl<T extends string>({
  options,
  value,
  onChange
}: SegmentedControlProps<T>) {
  return (
    <div className="mobile-segmented" role="tablist">
      {options.map((option) => {
        const active = option.value === value

        return (
          <button
            aria-selected={active}
            className={active ? "mobile-segmented__item is-active" : "mobile-segmented__item"}
            key={option.value}
            onClick={() => onChange(option.value)}
            role="tab"
            type="button"
          >
            {option.label}
          </button>
        )
      })}
    </div>
  )
}
