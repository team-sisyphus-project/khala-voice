import { useCallback, useMemo } from "react";
import { useSearchParams } from "react-router";

/**
 * 아카이브 필터 상태를 **URL 에 둔다.**
 *
 * 컴포넌트 state 에만 두면 필터를 걸어 찾은 화면을 공유할 수도, 새로고침 뒤에
 * 되찾을 수도, 뒤로가기로 돌아갈 수도 없다. 아카이브는 "찾아서 남에게 보내는"
 * 화면이라 이게 특히 아쉽다.
 *
 * sisyphus 는 모바일에 URL 라우트가 아예 없어 이런 상태가 전부 휘발됐다
 * (`docs/10-porting-map.md` B6).
 */
export type ArchiveStatus = "all" | "active" | "completed" | "archived";

export interface ArchiveFilters {
  status: ArchiveStatus;
  q: string;
  topicId: string | null;
  labelIds: string[];
  labelMode: "and" | "or";
  from: string | null;
  to: string | null;
  onlyMine: boolean;
}

const EMPTY: ArchiveFilters = {
  // 아카이브 탭이 회의 목록을 겸한다(2026-08-20). 기본은 **전부** 보여준다 —
  // 예전처럼 보관본만 기본으로 잡으면 방금 만든 회의가 목록에서 사라진다.
  status: "all",
  q: "",
  topicId: null,
  labelIds: [],
  labelMode: "and",
  from: null,
  to: null,
  onlyMine: false,
};

export function useArchiveFilters() {
  const [params, setParams] = useSearchParams();

  const filters = useMemo<ArchiveFilters>(
    () => ({
      status: parseStatus(params.get("status")),
      q: params.get("q") ?? "",
      topicId: params.get("topic") || null,
      labelIds: (params.get("labels") ?? "").split(",").filter(Boolean),
      labelMode: params.get("mode") === "or" ? "or" : "and",
      from: params.get("from") || null,
      to: params.get("to") || null,
      onlyMine: params.get("mine") === "1",
    }),
    [params],
  );

  const update = useCallback(
    (patch: Partial<ArchiveFilters>) => {
      const next = { ...filters, ...patch };
      const query = new URLSearchParams();

      if (next.status !== "all") query.set("status", next.status);
      if (next.q) query.set("q", next.q);
      if (next.topicId) query.set("topic", next.topicId);
      if (next.labelIds.length) query.set("labels", next.labelIds.join(","));
      // 기본값은 URL 에 쓰지 않는다 — 주소가 길어지기만 한다
      if (next.labelMode === "or") query.set("mode", "or");
      if (next.from) query.set("from", next.from);
      if (next.to) query.set("to", next.to);
      if (next.onlyMine) query.set("mine", "1");

      // 필터 조작은 히스토리를 쌓지 않는다. 뒤로가기가 필터 조작 이력으로
      // 가득 차면 "아카이브 화면에서 나가기"가 불가능해진다.
      setParams(query, { replace: true });
    },
    [filters, setParams],
  );

  const toggleLabel = useCallback(
    (id: string) => {
      const has = filters.labelIds.includes(id);
      update({
        labelIds: has ? filters.labelIds.filter((x) => x !== id) : [...filters.labelIds, id],
      });
    },
    [filters.labelIds, update],
  );

  const reset = useCallback(() => setParams(new URLSearchParams(), { replace: true }), [setParams]);

  const active =
    filters.status !== "all" ||
    filters.q !== "" ||
    filters.topicId !== null ||
    filters.labelIds.length > 0 ||
    filters.from !== null ||
    filters.to !== null ||
    filters.onlyMine;

  return { filters, update, toggleLabel, reset, active };
}

/**
 * 필터 → API 쿼리. **이 함수 한 곳에서만 변환한다** —
 * 호출부마다 매핑하면 화면과 서버가 다른 조건을 보게 된다.
 */
export function toApiParams(
  filters: ArchiveFilters,
  extra: { accountId?: string; limit?: number; offset?: number } = {},
): Record<string, string | undefined> {
  return {
    status: filters.status,
    order: filters.status === "archived" ? "archived_desc" : undefined,
    q: filters.q || undefined,
    topic_id: filters.topicId ?? undefined,
    label_ids: filters.labelIds.length ? filters.labelIds.join(",") : undefined,
    label_mode: filters.labelIds.length > 1 ? filters.labelMode : undefined,
    participant_id: filters.onlyMine ? extra.accountId : undefined,
    from: filters.from ? `${filters.from}T00:00:00Z` : undefined,
    to: filters.to ? `${filters.to}T23:59:59Z` : undefined,
    limit: extra.limit ? String(extra.limit) : undefined,
    offset: extra.offset ? String(extra.offset) : undefined,
  };
}

function parseStatus(value: string | null): ArchiveStatus {
  return value === "active" || value === "completed" || value === "archived" ? value : "all";
}

export { EMPTY as EMPTY_FILTERS };
