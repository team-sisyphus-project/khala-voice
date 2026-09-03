import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/api";
import { applyTheme, isTheme } from "@/lib/theme";
import { setUiLanguage } from "@/i18n";
import type { CurrentAccount } from "@core/api";

let cached: CurrentAccount | null = null;
const waiters = new Set<(account: CurrentAccount) => void>();

/**
 * 현재 계정. 앱 전체에서 한 번만 받아 공유한다.
 *
 * 서버가 준 테마로 정정한다 — 부팅 스크립트는 localStorage 캐시로
 * 먼저 칠했을 뿐이라 다른 기기에서 바꾼 값과 어긋날 수 있다.
 */
export function useAccount(): {
  account: CurrentAccount | null;
  setAccount: (account: CurrentAccount) => void;
} {
  const [account, setLocal] = useState<CurrentAccount | null>(cached);

  // 설정 화면이 값을 바꾸면 캐시도 같이 움직여야 한다 — 안 그러면 녹음 화면이
  // 옛 언어로 세션을 만든다.
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
