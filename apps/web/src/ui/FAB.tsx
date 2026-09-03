/**
 * **Source: devkanban** `mobile/src/components/FAB.tsx` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
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
