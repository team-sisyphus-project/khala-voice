import { useCallback, useEffect, useState } from "react";
import { onPrefsChange, readPrefs, writePrefs } from "@/lib/prefs";
import type { Prefs } from "@/lib/prefs";

/**
 * 녹음 기본값을 읽고 쓴다.
 *
 * 녹음 화면과 설정 화면이 같은 값을 본다 — 한쪽에서 바꾸면 다른 쪽도 따라간다
 * (`lib/prefs.ts` 의 이벤트).
 */
export function usePrefs(): [Prefs, (patch: Partial<Prefs>) => void] {
  const [prefs, setPrefs] = useState<Prefs>(readPrefs);

  useEffect(() => onPrefsChange(() => setPrefs(readPrefs())), []);

  const update = useCallback((patch: Partial<Prefs>) => {
    setPrefs(writePrefs(patch));
  }, []);

  return [prefs, update];
}
