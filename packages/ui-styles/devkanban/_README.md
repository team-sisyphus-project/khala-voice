# devkanban mobile styles — vendored as-is

**Source: devkanban** `mobile/src/styles/`.

To use the button press feedback · header treatment · inputs · modals · glassmorphism
surfaces exactly as-is, this was **copied untouched**. devkanban-only rules our screens
don't have (kanban board · chat · workplans) come along too — leaving them in place is
safer than breaking the cascade while cherry-picking rules.

| File | What |
|---|---|
| `tokens.css` | Design tokens · theme definitions (light/dark/cool/wc/pencil/game) |
| `base.css` | Reset and document defaults |
| `components.css` | Base component rules |
| `redesign.css` | The current design layered on top. **Must come after components.css** |
| `press.css` | Press feedback. Replaces each component's own `:active` with one system rule. **Goes last** |
| `game-skin.css` | Game theme. After press.css — its press grammar is inverted (pushes down), so it wins by order |

## Do not modify

Files in this directory must **stay identical to the source.** If we need adjustments,
they go separately in `apps/web/src/styles/overrides.css`. Touching files here makes it
impossible to tell what is ours and what is upstream once devkanban changes its design.

Source location: `devkanban/mobile/src/styles/`
Imported on: 2026-08-20
