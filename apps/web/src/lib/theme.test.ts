import { afterEach, describe, expect, it, vi } from "vitest";
import { applyTheme, cachedTheme } from "./theme";

const { updateTheme } = vi.hoisted(() => ({ updateTheme: vi.fn() }));

vi.mock("./api", () => ({ api: { updateTheme } }));

afterEach(() => {
  updateTheme.mockReset();
  vi.unstubAllGlobals();
});

describe("cachedTheme", () => {
  it("defaults to light when no valid preference exists", () => {
    vi.stubGlobal("localStorage", { getItem: () => null });
    expect(cachedTheme()).toBe("light");
  });

  it("keeps a valid saved theme", () => {
    vi.stubGlobal("localStorage", { getItem: () => "pencil-warm" });
    expect(cachedTheme()).toBe("pencil-warm");
  });
});

describe("applyTheme", () => {
  it("applies and persists the selected theme locally and to the account", async () => {
    const setAttribute = vi.fn();
    const setItem = vi.fn();
    updateTheme.mockResolvedValue(undefined);
    vi.stubGlobal("document", { documentElement: { setAttribute } });
    vi.stubGlobal("localStorage", { setItem });

    await applyTheme("dark");

    expect(setAttribute).toHaveBeenCalledWith("data-theme", "dark");
    expect(setItem).toHaveBeenCalledWith("vr:theme", "dark");
    expect(updateTheme).toHaveBeenCalledWith("dark");
  });
});
