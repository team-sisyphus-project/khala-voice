/**
 * **Source: devkanban** `mobile/src/components/Field.tsx` — brought over verbatim.
 *
 * To reuse the button press feedback, header treatment, inputs, and modal
 * styling as-is, even the markup (class names) matches the original. The CSS
 * is keyed to these names.
 */

import { useId } from "react"
import type { ReactNode } from "react"
import { Icon } from "./Icon"

type FieldProps = {
  label?: string
  icon?: string
  type?: string
  value: string
  placeholder?: string
  autoComplete?: string
  inputMode?: "text" | "email" | "numeric" | "search"
  disabled?: boolean
  error?: string | null
  hint?: ReactNode
  onChange: (value: string) => void
  onSubmit?: () => void
}

export function Field({
  label,
  icon,
  type = "text",
  value,
  placeholder,
  autoComplete,
  inputMode,
  disabled = false,
  error,
  hint,
  onChange,
  onSubmit
}: FieldProps) {
  const id = useId()

  return (
    <div className={error ? "mobile-field mobile-field--error" : "mobile-field"}>
      {label ? (
        <label className="mobile-field__label" htmlFor={id}>
          {label}
        </label>
      ) : null}
      <div className="mobile-field__control">
        {icon ? (
          <span className="mobile-field__icon">
            <Icon name={icon} />
          </span>
        ) : null}
        <input
          autoComplete={autoComplete}
          className="mobile-field__input"
          disabled={disabled}
          id={id}
          inputMode={inputMode}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => {
            if (onSubmit && event.key === "Enter") {
              event.preventDefault()
              onSubmit()
            }
          }}
          placeholder={placeholder}
          type={type}
          value={value}
        />
      </div>
      {error ? <p className="mobile-field__error">{error}</p> : null}
      {!error && hint ? <p className="mobile-field__hint">{hint}</p> : null}
    </div>
  )
}
