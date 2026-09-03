# 12. Design System

Ported from the `devkanban` theme system. Source: `assets/css/themes/*.css` + the `assets/css/app.css` :root.

## Four themes — chosen per user

**Not a system-admin setting.** It is a per-account value, changed by each user in settings.

| Theme | Character | Size | Loading |
|---|---|---|---|
| **Light** | Warm off-white · red accent | 2KB (gzip) | Bundled |
| **Dark** | Warm charcoal · red accent | 2KB (gzip) | Bundled |
| **Pencil** | Paper texture · sketched boxes | 66KB (gzip) | Bundled |
| **Game** | Pixels (phosphor) · dot-matrix font · scanlines | 10KB (gzip) | Bundled |

### Bundled loading

All four themes ship in the `packages/ui-styles` bundle. The old lazy-loaded Pencil/Game
files overrode the legacy token names and could no longer change anything under the current
`--mobile-*` token system, so they were removed. Switching themes only flips `data-theme`,
with no extra network request.

### Flash prevention

| Screen | Approach |
|---|---|
| LiveView | The server stamps `html[data-theme]` directly |
| React SPA | The `index.html` is static, so paint first from the localStorage cache, then correct via `/api/me` |

## Default theme

With no browser cache and no account value, Light is used. The React SPA applies this rule
in the static document's first paint and in `cachedTheme()`; LiveView and new accounts apply
it via the server default. A valid theme the user has saved is always preserved.

## Accent — red

devkanban uses orange, but this app uses **red**. The record button is red
(a red circle = recording, universally understood), and a mismatched accent looks off.

`accent.css` overrides only the `--accent` family after the theme files.
Surfaces, text, and borders are untouched — that's where each theme's identity lives.

**The Game theme is the exception.** Red, green, and amber form a line grammar meaning
"layer · object · execution," and changing the accent would break that semantic system.

## Token contract

`packages/ui-styles/devkanban/tokens.css` provides the name list and per-theme values.
Each `[data-theme="…"]` block overrides the shared `--mobile-*` tokens.

### Surface ladder

`canvas` is furthest back; higher numbers come forward.

| Token | Use |
|---|---|
| `--surface-canvas` | Page floor |
| `--surface-0` | Sections |
| `--surface-1` | Cards |
| `--surface-2` | Elements on cards |
| `--surface-3` | Modals · popovers |
| `--surface-inset` | Pressed-in areas (input fields) |

### Everything else

| Group | Tokens |
|---|---|
| Text | `--text-primary` `--text-secondary` `--text-tertiary` `--text-faint` |
| Borders | `--border-subtle` `--border-default` `--border-strong` `--divider` |
| Accent | `--accent` `--accent-hover` `--accent-soft` `--accent-strong` `--accent-text` |
| Status | `--status-{info,success,warning,error,attention}` (+ `-soft`) |
| Shadows | `--elev-1~3` `--elev-overlay` |
| Corners | `--radius-{xs,sm,md,lg,xl,full}` |

**Status colors keep their hue family even when the medium changes.** This is semantics, not aesthetics.

## data-surface roles

Medium themes like Pencil and Game paint **roles, not components.**
That way, adding components does not grow the skins.

| Role | What |
|---|---|
| `raised` | Things floating above the floor — cards · panels · modals · dropdowns |
| `sunken` | Places where values are entered — input · textarea · select |
| `control` | Things you press — buttons · chips · tabs · toggles |

**Untagged elements are not painted.** Any new container, input, or button must carry a tag.

## Component classes

`backend/assets/css/app.css`. LiveView and React use **the same file.**

| Class | Purpose |
|---|---|
| `.vr-card` / `.vr-card__body` | Cards |
| `.vr-notice--{info,warn,error,ok}` | Notice banners |
| `.vr-chip--{ok,warn,error,info,neutral}` | Status chips |
| `.vr-btn` `--primary` `--danger` `--ghost` `--outline` `--sm` | Buttons |
| `.vr-input` | Inputs |
| `.vr-label` / `.vr-hint` / `.vr-key` | Labels · hints · config keys |
| `.vr-app__*` / `.vr-tabbar__*` | React app shell · bottom tab bar |

## What ignores the theme

Values that are deliberately fixed.

| Item | Reason |
|---|---|
| **Record button red** (`--rec-*`) | A red circle = recording is a universal convention |
| **10-color speaker palette** | Its purpose is telling speakers apart; changing per theme would be confusing |
| **Icon font** | The Game theme forces the dot-matrix font on `*` with `!important`; if icons were caught, the ligatures would break and literal text like "mic" would show |

## Responsive

**Desktop and mobile are the same project, same routes, same components.**
Only the layout diverges by width.

| Width | Navigation |
|---|---|
| < 720px | Bottom tab bar (icon + label), top shows only the brand |
| ≥ 720px | Top nav, tab bar hidden |

Putting all the labels in the top bar wraps the text onto two lines at narrow widths.
The bottom tab bar uses `env(safe-area-inset-bottom)` to clear the iPhone home indicator.

## Accessibility

| Item | Handling |
|---|---|
| Motion | Respect **both** `prefers-reduced-motion` and `data-reduce-motion` |
| Blur | Can be turned off via `data-reduce-blur` |
| Touch targets | Minimum 44px (`--control-height`) |
| Color dependence | Information is never conveyed by color alone (speakers and statuses always carry labels) |
| Recording state | Changes announced via `aria-live` |

## Not ported

- **Watercolor** (`wc-cool` / `wc-warm`) — out of scope for now. If needed, take it from devkanban `media.css`
- `light-cool` / `dark-cool` / `custom` — temperature variants come later
- Task status colors, agent gradients — concepts this app doesn't have
