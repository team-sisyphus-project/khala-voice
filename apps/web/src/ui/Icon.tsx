/**
 * Icons = **Material Symbols Rounded**.
 *
 * The devkanban original (`mobile/src/Icon.tsx`) was an inline SVG registry.
 * Ported as-is, the names this app uses (`ios_share` · `arrow_upward` ·
 * `settings` …) weren't in the registry, so screens showed empty circles or
 * the raw name text. Better to **use a set that has everything** than to
 * curate one — it also matches the sisyphus / LiveView side.
 *
 * Names are Material Symbols names verbatim. The class name (`mobile-icon`)
 * stays — devkanban CSS is keyed to it.
 */

export function Icon({ name }: { name: string }) {
  return (
    <span aria-hidden="true" className="material-symbols-rounded mobile-icon">
      {name}
    </span>
  )
}
