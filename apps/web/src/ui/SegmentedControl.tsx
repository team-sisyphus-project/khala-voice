/**
 * **Source: devkanban** `mobile/src/components/SegmentedControl.tsx` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
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
