import { api } from "./api";

// Display names come from the i18n catalog (`theme.*`) — keyed by id. Only
// `game` has a different display name ("Pixel") while its id stays `game`: the
// CSS (`game-skin.css`) and the account schema (`@themes`) are keyed to this value.
export const THEMES = [
  { id: "light", icon: "light_mode" },
  { id: "dark", icon: "dark_mode" },
  { id: "pencil-warm", icon: "draw" },
  { id: "game", icon: "videogame_asset" },
] as const;

export type Theme = (typeof THEMES)[number]["id"];

/*
 * There used to be lazily loaded themes. Removed.
 *
 * The old `/themes/pencil.css` (247KB) and `/themes/game.css` (35KB) were
 * written to override the **old token names** (`--surface-*` · `--accent`);
 * after the design system moved to devkanban (`--mobile-*`) they changed
 * nothing while still costing a 280KB download.
 *
 * Now all four themes live inside `packages/ui-styles` —
 * light/dark in `devkanban/tokens.css`, pencil in `media-skin.css`,
 * game in `game-skin.css`.
 */

const STORAGE_KEY = "vr:theme";

export function isTheme(value: unknown): value is Theme {
  return typeof value === "string" && THEMES.some((t) => t.id === value);
}

export function cachedTheme(): Theme {
  const stored = localStorage.getItem(STORAGE_KEY);
  return isTheme(stored) ? stored : "light";
}

/** Apply the theme. All four themes are in the bundle — nothing fetched separately. */
export async function applyTheme(theme: Theme, options: { save?: boolean } = {}): Promise<void> {
  const root = document.documentElement;

  root.setAttribute("data-theme", theme);
  localStorage.setItem(STORAGE_KEY, theme);

  if (options.save !== false) {
    await api.updateTheme(theme).catch(() => {
      // Even if saving fails, leave the screen changed. The next load reverts to the server value.
    });
  }
}
