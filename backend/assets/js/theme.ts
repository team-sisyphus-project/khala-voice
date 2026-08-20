/**
 * 테마 적용과 지연 로드.
 *
 * ## 왜 지연 로드인가
 *
 * 연필 테마의 CSS 는 66KB(gzip) 다 — 종이 질감을 인라인 SVG 로 그리기 때문이다.
 * 대부분의 사용자가 쓰지 않을 것을 첫 로드에 태우지 않는다.
 * 라이트·다크는 합쳐 4KB 라 번들에 포함되어 있다.
 *
 * ## 깜빡임 방지
 *
 * 테마 CSS 가 도착하기 전에 화면이 그려지면 기본 라이트가 잠깐 보였다가 바뀐다.
 * 지연 테마를 쓸 때는 `data-theme-loading` 으로 body 를 숨기고,
 * CSS 가 붙은 뒤에 푼다.
 */

export const THEMES = ["light", "dark", "pencil-warm", "game"] as const;
export type Theme = (typeof THEMES)[number];

/** 번들에 없어서 따로 받아야 하는 테마 → CSS 경로 */
const LAZY: Partial<Record<Theme, string>> = {
  "pencil-warm": "/themes/pencil.css",
  game: "/themes/game.css",
};

const STORAGE_KEY = "vr:theme";
const loaded = new Set<string>();

export function isTheme(value: unknown): value is Theme {
  return typeof value === "string" && (THEMES as readonly string[]).includes(value);
}

/** 저장된 테마. 서버 값이 우선이고 localStorage 는 첫 페인트용 캐시다. */
export function currentTheme(): Theme {
  const stored = localStorage.getItem(STORAGE_KEY);
  return isTheme(stored) ? stored : "light";
}

/**
 * 테마를 적용한다. 필요하면 CSS 를 먼저 받는다.
 *
 * `persist: false` 로 부르면 미리보기만 하고 저장하지 않는다.
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
      // CSS 를 못 받으면 테마를 바꾸지 않는다. 반쯤 적용된 화면보다 낫다.
      root.removeAttribute("data-theme-loading");
      throw new Error("테마를 불러오지 못했습니다");
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
 * 첫 페인트 전에 부른다.
 *
 * localStorage 캐시로 즉시 적용하고, 지연 테마면 CSS 를 받는 동안 숨긴다.
 * 서버가 다른 값을 주면 나중에 `applyTheme` 로 정정된다.
 */
export function bootTheme(): void {
  const theme = currentTheme();
  document.documentElement.setAttribute("data-theme", theme);

  if (LAZY[theme]) {
    void applyTheme(theme, { persist: false }).catch(() => {});
  }
}
