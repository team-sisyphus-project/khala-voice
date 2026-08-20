import { api } from "./api";

export const THEMES = [
  { id: "light", label: "라이트", icon: "light_mode" },
  { id: "dark", label: "다크", icon: "dark_mode" },
  { id: "pencil-warm", label: "연필", icon: "draw" },
  { id: "game", label: "게임", icon: "videogame_asset" },
] as const;

export type Theme = (typeof THEMES)[number]["id"];

/*
 * 지연 로드 테마가 있었다. 없앴다.
 *
 * 옛 `/themes/pencil.css`(247KB) · `/themes/game.css`(35KB) 는 **옛 토큰 이름**
 * (`--surface-*` · `--accent`) 을 덮어쓰도록 쓰인 파일이라, 디자인 시스템을
 * devkanban(`--mobile-*`)으로 옮긴 뒤에는 아무것도 바꾸지 못하면서 280KB 만
 * 내려받게 만들었다.
 *
 * 지금은 네 테마가 전부 `packages/ui-styles` 안에 있다 —
 * 라이트·다크는 `devkanban/tokens.css`, 연필은 `media-skin.css`,
 * 게임은 `game-skin.css`.
 */

const STORAGE_KEY = "vr:theme";

export function isTheme(value: unknown): value is Theme {
  return typeof value === "string" && THEMES.some((t) => t.id === value);
}

export function cachedTheme(): Theme {
  const stored = localStorage.getItem(STORAGE_KEY);
  return isTheme(stored) ? stored : "dark";
}

/** 테마를 적용한다. 네 테마 모두 번들 안에 있어 따로 받지 않는다. */
export async function applyTheme(theme: Theme, options: { save?: boolean } = {}): Promise<void> {
  const root = document.documentElement;

  root.setAttribute("data-theme", theme);
  localStorage.setItem(STORAGE_KEY, theme);

  if (options.save !== false) {
    await api.updateTheme(theme).catch(() => {
      // 저장에 실패해도 화면은 바뀐 채로 둔다. 다음 로드에서 서버 값으로 돌아간다.
    });
  }
}

