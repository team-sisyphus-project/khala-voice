import { useCallback, useEffect, useState } from "react";
import { onPrefsChange, readPrefs, writePrefs } from "@/lib/prefs";
import type { Prefs } from "@/lib/prefs";

/**
 * Reads and writes the recording defaults.
 *
 * The recorder and settings screens see the same values — a change on one
 * side follows on the other (the event in `lib/prefs.ts`).
 */
export function usePrefs(): [Prefs, (patch: Partial<Prefs>) => void] {
  const [prefs, setPrefs] = useState<Prefs>(readPrefs);

  useEffect(() => onPrefsChange(() => setPrefs(readPrefs())), []);

  const update = useCallback((patch: Partial<Prefs>) => {
    setPrefs(writePrefs(patch));
  }, []);

  return [prefs, update];
}
