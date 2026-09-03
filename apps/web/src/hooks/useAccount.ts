import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/api";
import { applyTheme, isTheme } from "@/lib/theme";
import { setUiLanguage } from "@/i18n";
import type { CurrentAccount } from "@core/api";

let cached: CurrentAccount | null = null;
const waiters = new Set<(account: CurrentAccount) => void>();

/**
 * The current account. Fetched once and shared app-wide.
 *
 * Corrects to the server-given theme — the boot script only painted from the
 * localStorage cache first, which can disagree with a value changed on
 * another device.
 */
export function useAccount(): {
  account: CurrentAccount | null;
  setAccount: (account: CurrentAccount) => void;
} {
  const [account, setLocal] = useState<CurrentAccount | null>(cached);

  // When the settings screen changes a value, the cache must move with it —
  // otherwise the recording screen creates sessions with the old language.
  const setAccount = useCallback((next: CurrentAccount) => {
    cached = next;
    // UI language follows the account too — a settings change must re-render the
    // shell immediately, not on the next reload. No-op if unchanged.
    void setUiLanguage(next.locale);
    setLocal(next);
  }, []);

  useEffect(() => {
    if (cached) return;

    let alive = true;
    const notify = (a: CurrentAccount) => alive && setLocal(a);
    waiters.add(notify);

    if (waiters.size === 1) {
      void api
        .me()
        .then((me) => {
          cached = me;

          if (isTheme(me.theme) && me.theme !== localStorage.getItem("vr:theme")) {
            void applyTheme(me.theme, { save: false });
          }

          // Correct the display language to the account's stored value. The app
          // booted in English (the default); switch only if the account differs.
          void setUiLanguage(me.locale);

          for (const w of waiters) w(me);
          waiters.clear();
        })
        .catch(() => waiters.clear());
    }

    return () => {
      alive = false;
      waiters.delete(notify);
    };
  }, []);

  return { account, setAccount };
}
