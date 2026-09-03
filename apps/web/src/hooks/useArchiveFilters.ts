import { useCallback, useMemo } from "react";
import { useSearchParams } from "react-router";

/**
 * Archive filter state lives **in the URL.**
 *
 * Kept only in component state, a filtered view could not be shared, recovered
 * after a refresh, or returned to with the back button. The archive is a
 * "find it and send it to someone" screen, so that would hurt especially here.
 *
 * sisyphus had no URL routes on mobile at all, so all of this state
 * evaporated (`docs/10-porting-map.md` B6).
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
  // The archive tab doubles as the meeting list (2026-08-20). Default shows
  // **everything** — defaulting to archived only, as before, made a just-created
  // meeting vanish from the list.
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
      // Defaults aren't written to the URL — they'd only lengthen the address
      if (next.labelMode === "or") query.set("mode", "or");
      if (next.from) query.set("from", next.from);
      if (next.to) query.set("to", next.to);
      if (next.onlyMine) query.set("mine", "1");

      // Filter changes don't stack history. With back-navigation full of filter
      // tweaks, "leaving the archive screen" becomes impossible.
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
 * Filters → API query. **Converted in this one function only** —
 * mapping at every call site lets the screen and the server see different criteria.
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
