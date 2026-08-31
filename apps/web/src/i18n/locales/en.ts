/**
 * English UI catalog — the app's default display language.
 *
 * This is the seed catalog. Extracting the existing hardcoded Korean copy into
 * these keys is a later grain (grain-5/6); this file only establishes the
 * structure, the English-first tone baseline, and a handful of truly global
 * strings so the i18n instance boots with real content.
 *
 * Tone: concise, sentence-case, no trailing punctuation on button labels.
 *
 * Not `as const`: the English catalog defines the *shape* (keys), and every
 * other catalog (`ko`, …) is typed against it — so values stay plain strings,
 * not English literals, while a missing/extra key is still a compile error.
 */
export const en = {
  common: {
    appName: "Khala Voice",
    save: "Save",
    cancel: "Cancel",
    delete: "Delete",
    retry: "Retry",
    loading: "Loading…",
  },
};

export type UiCatalog = typeof en;

export default en;
