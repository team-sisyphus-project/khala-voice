/**
 * Mock adapter for `@/lib/theme`. This test exercises the *locale* wiring, not
 * theming — so `isTheme` reports "not a theme", which makes `useAccount`'s boot
 * effect skip `applyTheme` entirely. No DOM/IndexedDB/network is touched for
 * theme, keeping the test focused on the display-language path.
 */
export function isTheme(_value: unknown): boolean {
  return false;
}

export async function applyTheme(): Promise<void> {}
