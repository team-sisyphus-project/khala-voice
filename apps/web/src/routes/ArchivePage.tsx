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
 * 회의 목록 · 검색.
 *
 * 사용자 요구(2026-08-20): **"회의는 즉시 녹음, 아카이브는 회의의 목록."**
 * 그래서 이 화면이 목록의 집이다. 상태(진행 중 · 완료 · 보관)는 여기서 고른다.
 *
 * 검색 조건은 화면에 펼쳐 두지 않고 **우측 상단 아이콘 → 시트**로 접었다.
 * 목록이 주인공인데 조건이 첫 화면을 다 먹으면 안 된다.
 *
 * 필터 상태는 URL 에 있다 (`useArchiveFilters`) — 찾은 화면을 그대로 공유할 수 있어야 한다.
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
   * 접힌 토픽 그룹. **접힌 쪽을 기억한다** (펼친 쪽이 아니라) — 새 토픽이
   * 생기면 기본이 "펼침"이어야 목록에서 사라지지 않는다.
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

  // 입력 중에는 주소창만 바꾸고 요청은 멈춘 뒤에 보낸다
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

  // 필터가 바뀌면 처음부터 다시 본다
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

  // 상태 탭은 조건이 아니라 목록의 갈래다. 상단의 "필터 켜짐" 표시에서는 뺀다.
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
          {/* 분류는 여기서 필터로 쓰는 것이라 관리 화면도 이 안쪽에 둔다 */}
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
                  {/* 여러 개를 골랐을 때만 의미가 있다. 현재 모드가 늘 보여야
                      0건일 때 "왜 안 나오는지"를 알 수 있다. */}
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

            {/* 아이콘은 `icon` 프롭으로 준다. children 으로 넣으면 라벨 span
                안으로 들어가 아이콘과 글자가 두 줄로 쌓인다. */}
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
 * 토픽으로 묶는다.
 *
 * 순서는 토픽의 `sort_order` 를 따른다 — 분류 화면에서 정한 순서가 여기서도
 * 같아야 "위에 둔 것"이 의미를 갖는다. 토픽이 없는 회의는 **맨 아래** 한 덩어리로.
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

                    {/* 그룹 머리가 토픽을 이미 들고 있다. 라벨만 남긴다. */}
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
