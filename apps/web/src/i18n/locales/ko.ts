import type { UiCatalog } from "./en";

/**
 * Korean UI catalog. Mirrors the English catalog's key structure exactly
 * (typed against `UiCatalog`), so a missing or extra key is a compile error.
 */
export const ko: UiCatalog = {
  common: {
    appName: "Khala Voice",
    save: "저장",
    cancel: "취소",
    delete: "삭제",
    retry: "다시 시도",
    loading: "불러오는 중…",
  },
};

export default ko;
