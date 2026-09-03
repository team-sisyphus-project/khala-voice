/**
 * Theme application and lazy loading.
 *
 * ## Why lazy loading
 *
 * The pencil theme's CSS is 66KB (gzip) — it draws its paper texture with
 * inline SVG. We do not ship something most users will never use on first load.
 * Light and dark together are 4KB, so they are included in the bundle.
 *
 * ## Flicker prevention
 *
 * If the screen paints before the theme CSS arrives, the default light theme
 * flashes briefly and then changes. For lazy themes we hide the body with
 * `data-theme-loading` and release it once the CSS is attached.
 */

export const THEMES = ["light", "dark", "pencil-warm", "game"] as const;
export type Theme = (typeof THEMES)[number];

/** Themes not in the bundle that must be fetched separately → CSS path */
const LAZY: Partial<Record<Theme, string>> = {
  "pencil-warm": "/themes/pencil.css",
  game: "/themes/game.css",
};

const STORAGE_KEY = "vr:theme";
const loaded = new Set<string>();

export function isTheme(value: unknown): value is Theme {
  return typeof value === "string" && (THEMES as readonly string[]).includes(value);
}

/** The saved theme. The server value wins; localStorage is a cache for first paint. */
export function currentTheme(): Theme {
  const stored = localStorage.getItem(STORAGE_KEY);
  return isTheme(stored) ? stored : "light";
}

/**
 * Applies a theme, fetching its CSS first if needed.
 *
 * Called with `persist: false`, it only previews and does not save.
 */
export async function applyTheme(theme: Theme, options: { persist?: boolean } = {}): Promise<void> {
  const root = document.documentElement;
  const href = LAZY[theme];

  if (href && !loaded.has(href)) {
    root.setAttribute("data-theme-loading", "true");

    try {
      await loadStylesheet(href);
      loaded.add(href);
    } catch {
      // If the CSS fails to load, don't switch themes. Better than a half-applied screen.
      root.removeAttribute("data-theme-loading");
      throw new Error("Failed to load theme");
    }

    root.removeAttribute("data-theme-loading");
  }

  root.setAttribute("data-theme", theme);

  if (options.persist !== false) {
    localStorage.setItem(STORAGE_KEY, theme);
  }
}

function loadStylesheet(href: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const existing = document.querySelector<HTMLLinkElement>(`link[data-vr-theme="${href}"]`);
    if (existing) return resolve();

    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = href;
    link.dataset.vrTheme = href;
    link.onload = () => resolve();
    link.onerror = () => reject(new Error(href));

    document.head.appendChild(link);
  });
}

/**
 * Called before first paint.
 *
 * Applies immediately from the localStorage cache; for a lazy theme, hides the
 * screen while its CSS downloads. If the server says otherwise, `applyTheme`
 * corrects it later.
 */
export function bootTheme(): void {
  const theme = currentTheme();
  document.documentElement.setAttribute("data-theme", theme);

  if (LAZY[theme]) {
    void applyTheme(theme, { persist: false }).catch(() => {});
  }
}
