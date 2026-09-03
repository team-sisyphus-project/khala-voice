/**
 * The top bar's **round glass button**.
 *
 * **Source: devkanban** — uses the `mobile-top-app-bar__icon-button` class and
 * its CSS as-is. devkanban only wrote this markup inline inside TopAppBar, but
 * this app's top actions differ per screen, so it's extracted into a
 * component. **The look matches the original.**
 *
 * Top actions are icon-only. An icon+text button would weigh the same as the
 * title capsule, making the top read as two blobs.
 */

import { Icon } from "./Icon"

type IconButtonProps = {
  icon: string
  label: string
  onClick?: () => void
  disabled?: boolean
  /** On state (filters applied, etc.) */
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
