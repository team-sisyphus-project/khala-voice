import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { routesFor } from "../lib/routes";
import { SETTINGS_SECTIONS } from "./settingsStructure";

const settingsSource = readFileSync(
  fileURLToPath(new URL("./AppSettingsPage.tsx", import.meta.url)),
  "utf8",
);
const stylesSource = readFileSync(
  fileURLToPath(new URL("../../../../packages/ui-styles/overrides.css", import.meta.url)),
  "utf8",
);
const baseStylesSource = readFileSync(
  fileURLToPath(new URL("../../../../packages/ui-styles/devkanban/base.css", import.meta.url)),
  "utf8",
);
const liveViewStylesSource = readFileSync(
  fileURLToPath(new URL("../../../../backend/assets/css/app.css", import.meta.url)),
  "utf8",
);
const indexSource = readFileSync(fileURLToPath(new URL("../../index.html", import.meta.url)), "utf8");

describe("settings integration contract", () => {
  it("renders every declared setting and uses token-backed section cards", () => {
    const items = SETTINGS_SECTIONS.flatMap(({ items }) => items);

    for (const item of items) {
      expect(settingsSource).toContain(`case "${item}":`);
    }
    expect(settingsSource).toContain('card className="vr-settings-section"');

    const scopedStyles = stylesSource.slice(
      stylesSource.indexOf("/* ── 설정 묶음"),
      stylesSource.indexOf("/* ── 녹음 설정 줄"),
    );
    expect(scopedStyles).not.toMatch(/#[\da-f]{3,8}\b|(?:rgb|hsl|oklch)\(/i);
    expect(scopedStyles).not.toMatch(/(?:^|[\s:(,])-?\d*\.?\d+px\b/m);
    expect(scopedStyles).toContain("var(--mobile-radius-sm)");
    expect(scopedStyles).toContain("var(--mobile-surface-item)");

    const cardStyles = stylesSource.match(/\.mobile-section--card\s*{[^}]+}/s)?.[0];
    expect(cardStyles).not.toMatch(/#[\da-f]{3,8}\b|(?:rgb|hsl|oklch)\(/i);
    expect(cardStyles).not.toMatch(/(?:^|[\s:(,])-?\d*\.?\d+px\b/m);
    expect(cardStyles).toContain("var(--mobile-radius-md)");
    expect(cardStyles).toContain("var(--mobile-border-width)");
    expect(cardStyles).toContain("var(--mobile-shadow-card)");

    const accountCardStyles = liveViewStylesSource.match(/\.vr-card\s*{[^}]+}/s)?.[0];
    expect(accountCardStyles).not.toMatch(/#[\da-f]{3,8}\b|(?:rgb|hsl|oklch)\(/i);
    expect(accountCardStyles).not.toMatch(/(?:^|[\s:(,])-?\d*\.?\d+px\b/m);
    expect(accountCardStyles).toContain("var(--mobile-radius-md)");
    expect(accountCardStyles).toContain("var(--mobile-shadow-card)");
  });

  it("keeps settings reachable on both application surfaces", () => {
    expect(routesFor("m").settings).toBe("/m/settings");
    expect(routesFor("app").settings).toBe("/app/settings");
  });

  it("prevents double-tap and pinch zoom at mobile viewports", () => {
    expect(baseStylesSource).toMatch(/html,\s*body\s*{[^}]*touch-action:\s*manipulation;/s);
    expect(indexSource).toContain(
      'content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover"',
    );
  });
});
