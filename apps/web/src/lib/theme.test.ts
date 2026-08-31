import { afterEach, describe, expect, it, vi } from "vitest";
import { cachedTheme } from "./theme";

vi.mock("./api", () => ({ api: {} }));

afterEach(() => {
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
