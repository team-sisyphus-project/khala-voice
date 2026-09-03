import type { CurrentAccount } from "@core/api";

/**
 * Mock adapter for the real `@/lib/api` singleton, so the locale-wiring test can
 * exercise the *real* `useAccount` without a network or the full core/Uploader
 * (IndexedDB) stack. Only the two calls `useAccount`/`LocaleField` make are
 * modelled: `me()` (boot) and `updateLocale()` (the picker save).
 *
 * `me()` is driven per test via `__cfg.me`; `updateLocale()` echoes the saved
 * locale exactly as the backend `PATCH /api/me/locale` does.
 */

/** Build a complete account row; tests override just the fields they assert on. */
export function account(overrides: Partial<CurrentAccount> = {}): CurrentAccount {
  return {
    id: "acc_1",
    email: "person@example.com",
    name: null,
    locale: "en",
    theme: "dark",
    transcribe_language: null,
    confirmed: true,
    is_admin: false,
    ...overrides,
  };
}

/** Per-test control point for the boot `api.me()` response. */
export const __cfg: { me: () => Promise<CurrentAccount> } = {
  me: async () => account(),
};

export const api = {
  me: (): Promise<CurrentAccount> => __cfg.me(),
  updateLocale: async (locale: string): Promise<CurrentAccount> => account({ locale }),
  updateTheme: async (theme: string): Promise<CurrentAccount> => account({ theme }),
};
