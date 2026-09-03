import { describe, expect, it } from "vitest";
import { SETTINGS_SECTIONS } from "./settingsStructure";

describe("settings information architecture", () => {
  it("keeps every existing setting in exactly one of the four required sections", () => {
    expect(SETTINGS_SECTIONS.map(({ title }) => title)).toEqual([
      "화면",
      "녹음",
      "알림",
      "계정 및 보안",
    ]);

    const items = SETTINGS_SECTIONS.flatMap(({ items }) => items);

    expect(items).toEqual([
      "theme",
      "install",
      "microphone-and-language",
      "completion-notification",
      "billing",
      "integrations",
      "account",
    ]);
    expect(new Set(items).size).toBe(items.length);
  });
});
