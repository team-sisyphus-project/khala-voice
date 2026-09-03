import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { Link } from "react-router";
import i18n from "@/i18n";
import { api } from "@/lib/api";
import { useRoutes } from "@/lib/routes";
import { formatDuration, formatRelative } from "@/lib/format";
import { AppShell } from "@/components/AppShell";
import { Tag, TagRow } from "@/components/Tag";
import { Card, CardBody, EmptyState, Notice, Spinner } from "@/components/ui";
import { toApiParams, useArchiveFilters } from "@/hooks/useArchiveFilters";
import type { ArchiveStatus } from "@/hooks/useArchiveFilters";
import type { CurrentAccount, Label, Meeting, Topic } from "@core/api";
import { Button, Icon, IconButton, SegmentedControl, Sheet, StatusChip } from "@/ui";

const PAGE_SIZE = 30;

const STATUS_TABS: { value: ArchiveStatus; labelKey: string }[] = [
  { value: "all", labelKey: "archive.statusAll" },
  { value: "active", labelKey: "archive.statusActive" },
  { value: "completed", labelKey: "archive.statusCompleted" },
  { value: "archived", labelKey: "archive.statusArchived" },
];

/**
 * Meeting list & search.
 *
 * User requirement (2026-08-20): **"Meetings = record now; Archive = the list
 * of meetings."** So this screen is the list's home. Status (active ·
 * completed · archived) is chosen here.
 *
 * Search criteria aren't spread across the screen — they're folded behind the
 * **top-right icon → sheet**. The list is the star; criteria must not eat the
 * first screen.
 *
 * Filter state lives in the URL (`useArchiveFilters`) — a found view must be
 * shareable as-is.
 */
export function ArchivePage() {
  const { t } = useTranslation();
  const routes = useRoutes();
  const { filters, update, toggleLabel, reset, active } = useArchiveFilters();

  const [meetings, setMeetings] = useState<Meeting[] | null>(null);
  const [total, setTotal] = useState(0);
  const [shown, setShown] = useState(PAGE_SIZE);
  const [topics, setTopics] = useState<Topic[]>([]);
  const [labels, setLabels] = useState<Label[]>([]);
  const [me, setMe] = useState<CurrentAccount | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [sheet, setSheet] = useState(false);

  /**
   * Collapsed topic groups. **Remember the collapsed ones** (not the expanded
   * ones) — a new topic must default to "expanded" so it doesn't vanish from
   * the list.
   */
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());

  const toggleGroup = useCallback((key: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }, []);

  // While typing, only the address bar changes; the request goes out after a pause
  const [draft, setDraft] = useState(filters.q);
  const typing = useRef(false);

  useEffect(() => {
    void api.listTopics().then((r) => setTopics(r.topics)).catch(() => {});
    void api.listLabels().then((r) => setLabels(r.labels)).catch(() => {});
    void api.me().then(setMe).catch(() => {});
  }, []);

  useEffect(() => {
    if (typing.current) return;
    setDraft(filters.q);
  }, [filters.q]);

  useEffect(() => {
    const timer = setTimeout(() => {
      typing.current = false;
      if (draft !== filters.q) update({ q: draft });
    }, 350);

    return () => clearTimeout(timer);
  }, [draft, filters.q, update]);

  const params = useMemo(
    () => toApiParams(filters, { accountId: me?.id, limit: shown }),
    [filters, me?.id, shown],
  );

  const search = useCallback(async () => {
    setMeetings(null);
    setError(null);

    try {
      const result = await api.listMeetings(params);
      setMeetings(result.meetings);
      setTotal(result.total);
    } catch (e) {
      setError(e instanceof Error ? e.message : t("archive.searchError"));
      setMeetings([]);
    }
  }, [params]);

  useEffect(() => {
    void search();
  }, [search]);

  // When filters change, start viewing from the top again
  useEffect(() => {
    setShown(PAGE_SIZE);
  }, [
    filters.status,
    filters.q,
    filters.topicId,
    filters.labelIds.length,
    filters.labelMode,
    filters.from,
    filters.to,
    filters.onlyMine,
  ]);

  const multipleLabels = filters.labelIds.length > 1;

  // Status tabs are branches of the list, not criteria. Excluded from the "filters on" indicator up top.
  const narrowed =
    filters.q !== "" ||
    filters.topicId !== null ||
    filters.labelIds.length > 0 ||
    filters.from !== null ||
    filters.to !== null ||
    filters.onlyMine;

  return (
    <AppShell
      active="archive"
      title={t("archive.title")}
      subtitle={t("archive.subtitle")}
      actions={
        <>
          <IconButton
            icon="tune"
            label={narrowed ? t("archive.filtersApplied") : t("archive.filters")}
            active={narrowed}
            onClick={() => setSheet(true)}
          />
          {/* Taxonomy is used as a filter here, so its management screen also lives inside this one */}
          <Link
            className="mobile-top-app-bar__icon-button"
            to={routes.taxonomy}
            aria-label={t("archive.manageTaxonomy")}
            title={t("archive.manageTaxonomy")}
          >
            <span aria-hidden="true" className="material-symbols-rounded mobile-icon">
              sell
            </span>
          </Link>
        </>
      }
    >
      {error && <Notice kind="error" icon="error">{error}</Notice>}

      <SegmentedControl
        options={STATUS_TABS.map((tab) => ({ value: tab.value, label: t(tab.labelKey) }))}
        value={filters.status}
        onChange={(value) => update({ status: value as ArchiveStatus })}
      />

      <div className="vr-filter__summary vr-filter__summary--bare">
        <span>
          {meetings === null ? t("archive.searching") : t("archive.results", { count: total })}
          {narrowed && t("archive.filteredSuffix")}
        </span>
        {active && (
          <Button variant="ghost" fit onClick={reset}>
            {t("archive.clearFilters")}
          </Button>
        )}
      </div>

      {meetings === null && <Spinner label={t("archive.searching")} />}

      {meetings?.length === 0 && (
        <Card>
          <CardBody>
            <EmptyState
              icon="inventory_2"
              title={narrowed ? t("archive.emptyNarrowedTitle") : t("archive.emptyTitle")}
              desc={
                narrowed
                  ? multipleLabels && filters.labelMode === "and"
                    ? t("archive.emptyHintLabels")
                    : t("archive.emptyHintNarrow")
                  : t("archive.emptyHintNone")
              }
            >
              {active && (
                <Button variant="secondary" full onClick={reset}>
                  {t("archive.clearFilters")}
                </Button>
              )}
            </EmptyState>
          </CardBody>
        </Card>
      )}

      {meetings && meetings.length > 0 && (
        <>
          {groupByTopic(meetings).map((group) => (
            <TopicGroup
              key={group.key}
              group={group}
              open={!collapsed.has(group.key)}
              onToggle={() => toggleGroup(group.key)}
            />
          ))}

          {meetings.length < total && (
            <Button variant="secondary" full onClick={() => setShown((n) => n + PAGE_SIZE)}>
              {t("archive.loadMore", { shown: meetings.length, total })}
            </Button>
          )}
        </>
      )}

      {sheet && (
        <Sheet title={t("archive.filters")} onClose={() => setSheet(false)}>
          <div className="vr-filter">
            <div className="vr-filter__group">
              <span className="vr-filter__label">{t("archive.query")}</span>
              <input
                className="mobile-field__input"
                value={draft}
                onChange={(e) => {
                  typing.current = true;
                  setDraft(e.target.value);
                }}
                placeholder={t("archive.queryPlaceholder")}
                aria-label={t("archive.query")}
              />
            </div>

            {topics.length === 0 && labels.length === 0 && (
              <p className="vr-note vr-note--small">
                <Trans
                  t={t}
                  i18nKey="archive.taxonomyHint"
                  components={{ link: <Link to={routes.taxonomy} /> }}
                />
              </p>
            )}

            {topics.length > 0 && (
              <div className="vr-filter__group">
                <span className="vr-filter__label">{t("archive.topic")}</span>
                <div className="vr-filter__chips">
                  {topics.map((topic) => (
                    <Tag
                      key={topic.id}
                      item={topic}
                      kind="topic"
                      pressed={filters.topicId === topic.id}
                      onClick={() =>
                        update({ topicId: filters.topicId === topic.id ? null : topic.id })
                      }
                    />
                  ))}
                </div>
              </div>
            )}

            {labels.length > 0 && (
              <div className="vr-filter__group">
                <span className="vr-filter__label">
                  {t("archive.label")}
                  {/* Only meaningful with multiple selections. The current mode
                      must always show so a zero-result view explains "why nothing shows". */}
                  {multipleLabels && (
                    <>
                      {" · "}
                      <button
                        type="button"
                        className="vr-filter__mode"
                        onClick={() =>
                          update({ labelMode: filters.labelMode === "and" ? "or" : "and" })
                        }
                        title={t("archive.labelModeTitle")}
                      >
                        {filters.labelMode === "and" ? t("archive.labelModeAll") : t("archive.labelModeAny")}
                      </button>
                    </>
                  )}
                </span>
                <div className="vr-filter__chips">
                  {labels.map((label) => (
                    <Tag
                      key={label.id}
                      item={label}
                      pressed={filters.labelIds.includes(label.id)}
                      onClick={() => toggleLabel(label.id)}
                    />
                  ))}
                </div>
              </div>
            )}

            <div className="vr-filter__group">
              <span className="vr-filter__label">{t("archive.period")}</span>
              <div className="vr-filter__range">
                <input
                  type="date"
                  className="mobile-field__input"
                  value={filters.from ?? ""}
                  max={filters.to ?? undefined}
                  onChange={(e) => update({ from: e.target.value || null })}
                  aria-label={t("archive.startDate")}
                />
                <span aria-hidden="true">~</span>
                <input
                  type="date"
                  className="mobile-field__input"
                  value={filters.to ?? ""}
                  min={filters.from ?? undefined}
                  onChange={(e) => update({ to: e.target.value || null })}
                  aria-label={t("archive.endDate")}
                />
              </div>
            </div>

            {/* Pass the icon via the `icon` prop. Put it in children and it lands
                inside the label span, stacking icon and text on two lines. */}
            <Button
              variant={filters.onlyMine ? "primary" : "secondary"}
              icon={filters.onlyMine ? "check" : "group"}
              onClick={() => update({ onlyMine: !filters.onlyMine })}
            >
              {t("archive.onlyMine")}
            </Button>

            <div className="vr-filter__actions">
              {active && (
                <Button variant="ghost" onClick={reset}>
                  {t("archive.clearAll")}
                </Button>
              )}
              <Button full onClick={() => setSheet(false)}>
                {t("common.close")}
              </Button>
            </div>
          </div>
        </Sheet>
      )}
    </AppShell>
  );
}

type Group = { key: string; topic: Topic | null; meetings: Meeting[] };

/**
 * Group by topic.
 *
 * Order follows the topics' `sort_order` — the order set on the taxonomy
 * screen must match here for "what I put on top" to mean anything. Meetings
 * with no topic go in one block at the **very bottom**.
 */
function groupByTopic(meetings: Meeting[]): Group[] {
  const groups = new Map<string, Group>();

  for (const meeting of meetings) {
    const key = meeting.topic?.id ?? "";
    const group = groups.get(key);

    if (group) group.meetings.push(meeting);
    else groups.set(key, { key, topic: meeting.topic ?? null, meetings: [meeting] });
  }

  return [...groups.values()].sort((a, b) => {
    if (!a.topic) return 1;
    if (!b.topic) return -1;
    return a.topic.sort_order - b.topic.sort_order;
  });
}

function TopicGroup({
  group,
  open,
  onToggle,
}: {
  group: Group;
  open: boolean;
  onToggle: () => void;
}) {
  const { t } = useTranslation();
  return (
    <section className="vr-group">
      <button
        type="button"
        className="vr-group__head"
        onClick={onToggle}
        aria-expanded={open}
      >
        <Icon name={open ? "expand_more" : "chevron_right"} />
        {group.topic ? (
          <Tag item={group.topic} kind="topic" />
        ) : (
          <span className="vr-group__none">{t("archive.noTopic")}</span>
        )}
        <span className="vr-group__count">{group.meetings.length}</span>
      </button>

      {open && (
        <div className="vr-group__body">
          {group.meetings.map((meeting) => (
            <Link key={meeting.id} to={`/app/meetings/${meeting.id}`} className="vr-card-link">
              <Card>
                <CardBody>
                  <div className="vr-result">
                    <div className="vr-result__head">
                      <div className="vr-result__title">{meeting.title || t("common.untitled")}</div>
                      <StatusChip status={meeting.status} label={statusLabel(meeting.status)} />
                    </div>

                    <div className="vr-result__meta">
                      {formatRelative(meeting.archived_at ?? meeting.started_at)}
                      {meeting.total_duration_seconds > 0 &&
                        ` · ${formatDuration(meeting.total_duration_seconds)}`}
                    </div>

                    {/* The group header already carries the topic. Keep only the labels. */}
                    <TagRow labels={meeting.labels} />

                    {meeting.summary && <p className="vr-result__summary">{meeting.summary}</p>}
                  </div>
                </CardBody>
              </Card>
            </Link>
          ))}
        </div>
      )}
    </section>
  );
}

function statusLabel(status: string): string {
  switch (status) {
    case "active":
      return i18n.t("archive.statusActive");
    case "completed":
      return i18n.t("archive.statusCompleted");
    case "archived":
      return i18n.t("archive.statusArchived");
    default:
      return status;
  }
}
