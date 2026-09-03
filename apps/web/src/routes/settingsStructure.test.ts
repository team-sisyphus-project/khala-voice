import { describe, expect, it } from "vitest";
import { SETTINGS_SECTIONS } from "./settingsStructure";

describe("settings information architecture", () => {
  it("keeps every existing setting in exactly one of the four required sections", () => {
    expect(SETTINGS_SECTIONS.map(({ title }) => title)).toEqual([
      "Display",
      "Recording",
      "Notifications",
      "Account & security",
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
