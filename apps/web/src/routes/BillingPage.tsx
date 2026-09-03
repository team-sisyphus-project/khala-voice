import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router";
import i18n from "@/i18n";
import { api } from "@/lib/api";
import { useRoutes } from "@/lib/routes";
import { AppShell } from "@/components/AppShell";
import { Card, CardBody, Chip, EmptyState, Notice, Spinner } from "@/components/ui";
import { formatDateTime, formatRelative } from "@/lib/format";
import type { BillingSummary, LedgerEntry } from "@core/api";
import { Icon } from "@/ui";

/**
 * My credits and usage history.
 *
 * **Source: devkanban** — its billing screen layout. This app has no paid
 * plans, so there are no payment/upgrade paths; it shows **only the balance
 * and its evidence**.
 *
 * ## Negative balances aren't hidden
 *
 * Usage metering happens after the work completes, so it's recorded even when
 * the balance falls short (overdraft). Rounding that state up to 0 would make
 * it impossible to explain why next month's grant shrank.
 */
export function BillingPage() {
  const { t } = useTranslation();
  const routes = useRoutes();
  const navigate = useNavigate();
  const [summary, setSummary] = useState<BillingSummary | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void api
      .billing()
      .then(setSummary)
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : t("billing.loadError"));
      });
  }, [t]);

  if (error) {
    return (
      <AppShell active="settings" title={t("billing.title")}>
        <Notice kind="error" icon="error">{error}</Notice>
      </AppShell>
    );
  }

  if (!summary) {
    return (
      <AppShell active="settings" title={t("billing.title")}>
        <Spinner label={t("common.loading")} />
      </AppShell>
    );
  }

  const overdrawn = summary.balance < 0;

  return (
    <AppShell
      active="settings"
      title={t("billing.title")}
      subtitle={t("billing.subtitle")}
      onBack={() => navigate(routes.settings)}
    >
      <Card className="mb-4">
        <CardBody>
          <div style={{ display: "flex", alignItems: "baseline", gap: 10, flexWrap: "wrap" }}>
            <span
              style={{
                fontSize: 34,
                fontWeight: 300,
                fontVariantNumeric: "tabular-nums",
                color: overdrawn ? "var(--status-error)" : "var(--text-primary)",
              }}
            >
              {summary.balance.toLocaleString(i18n.language)}
            </span>
            <span className="mobile-row__meta">{t("billing.creditsUnit")}</span>

            {summary.plan && (
              <Chip kind="info">
                {summary.plan.display_name}
                {summary.plan.included_credits
                  ? ` · ${t("billing.perMonth", { amount: summary.plan.included_credits.toLocaleString(i18n.language) })}`
                  : ""}
              </Chip>
            )}
          </div>

          {summary.subscription && (
            <p className="vr-note" style={{ marginTop: 8, fontSize: 12 }}>
              {t("billing.currentPeriod", {
                start: formatDateTime(summary.subscription.current_period_start),
                end: formatDateTime(summary.subscription.current_period_end),
              })}
            </p>
          )}

          {overdrawn && (
            <Notice kind="warn" icon="info" className="mt-2">
              {t("billing.negativeBalance")}
            </Notice>
          )}
        </CardBody>
      </Card>

      {summary.lots.length > 0 && (
        <Card className="mb-4">
          <CardBody>
            <h2 className="mobile-section__title">{t("billing.remaining")}</h2>
            <p className="vr-note" style={{ fontSize: 12, margin: "2px 0 10px" }}>
              {t("billing.expiryOrder")}
            </p>

            <div style={{ display: "flex", flexDirection: "column" }}>
              {summary.lots.map((lot) => (
                <div
                  key={lot.id}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "space-between",
                    gap: 12,
                    padding: "8px 0",
                    borderBottom: "var(--hairline-width) solid var(--border-subtle)",
                  }}
                >
                  <div>
                    <div style={{ fontSize: 14, color: "var(--text-primary)", fontWeight: 600 }}>
                      {lotLabel(lot.source)}
                    </div>
                    <div className="vr-note vr-note--small">
                      {lot.expires_at
                        ? t("billing.expiresAt", { date: formatDateTime(lot.expires_at) })
                        : t("billing.noExpiry")}
                    </div>
                  </div>

                  <span
                    style={{
                      fontVariantNumeric: "tabular-nums",
                      color: lot.remaining < 0 ? "var(--status-error)" : "var(--text-primary)",
                    }}
                  >
                    {lot.remaining.toLocaleString(i18n.language)}
                  </span>
                </div>
              ))}
            </div>
          </CardBody>
        </Card>
      )}

      <Card>
        <CardBody>
          <h2 className="mobile-section__title">{t("billing.usageHistory")}</h2>

          {summary.entries.length === 0 ? (
            <EmptyState icon="receipt_long" title={t("billing.noUsage")} />
          ) : (
            <div style={{ display: "flex", flexDirection: "column", marginTop: 8 }}>
              {summary.entries.map((entry) => (
                <EntryRow key={entry.id} entry={entry} />
              ))}
            </div>
          )}
        </CardBody>
      </Card>
    </AppShell>
  );
}

function EntryRow({ entry }: { entry: LedgerEntry }) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const spent = entry.delta < 0;
  const details = detailLines(entry);

  return (
    <div
      style={{
        padding: "10px 0",
        borderBottom: "var(--hairline-width) solid var(--border-subtle)",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <span style={{ color: "var(--mobile-fg-subtle)", display: "inline-flex" }}>
          <Icon name={domainIcon(entry)} />
        </span>

        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={{ fontSize: 14, color: "var(--text-primary)" }}>
            {entry.reason || sourceLabel(entry.source)}
          </div>
          <div className="vr-note vr-note--small">
            {formatRelative(entry.inserted_at)}
          </div>
        </div>

        <span
          style={{
            fontVariantNumeric: "tabular-nums",
            fontWeight: 600,
            color: spent ? "var(--text-secondary)" : "var(--status-success)",
          }}
        >
          {spent ? "" : "+"}
          {entry.delta.toLocaleString(i18n.language)}
        </span>

        {details.length > 0 && (
          <button
            className="mobile-button mobile-button--ghost mobile-button--fit"
            onClick={() => setOpen(!open)}
            aria-expanded={open}
            aria-label={t("billing.calcBasis")}
          >
            <Icon name={open ? "expand_less" : "expand_more"} />
          </button>
        )}
      </div>

      {/* The only evidence for "why did this much get spent". Folded away, but never removed. */}
      {open && (
        <dl className="vr-usage">
          {details.map(([term, value]) => (
            <div key={term}>
              <dt>{term}</dt>
              <dd>{value}</dd>
            </div>
          ))}
        </dl>
      )}
    </div>
  );
}

function detailLines(entry: LedgerEntry): [string, string][] {
  const snapshot = entry.pricing_snapshot;
  if (!snapshot) return [];

  const lines: [string, string][] = [];
  const get = (key: string) => snapshot[key];

  if (get("minutes"))
    lines.push([
      i18n.t("billing.detailLength"),
      i18n.t("billing.detailLengthValue", { minutes: String(get("minutes")) }),
    ]);
  if (get("model")) lines.push([i18n.t("billing.detailModel"), String(get("model"))]);

  if (get("input_tokens") || get("output_tokens")) {
    lines.push([
      i18n.t("billing.detailTokens"),
      i18n.t("billing.detailTokensValue", {
        input: Number(get("input_tokens") ?? 0).toLocaleString(i18n.language),
        output: Number(get("output_tokens") ?? 0).toLocaleString(i18n.language),
      }),
    ]);
  }

  if (entry.usage_cost_usd) lines.push([i18n.t("billing.detailCost"), `$${entry.usage_cost_usd}`]);

  return lines;
}

function domainIcon(entry: LedgerEntry): string {
  if (entry.delta > 0) return "add_circle";

  switch (entry.charge_domain) {
    case "stt":
      return "graphic_eq";
    case "llm":
      return "summarize";
    default:
      return "remove_circle";
  }
}

function sourceLabel(source: string): string {
  switch (source) {
    case "plan_grant":
      return i18n.t("billing.sourcePlanGrant");
    case "admin_grant":
      return i18n.t("billing.sourceAdminGrant");
    case "usage":
      return i18n.t("billing.sourceUsage");
    case "expiry":
      return i18n.t("billing.sourceExpiry");
    case "admin_revoke":
      return i18n.t("billing.sourceAdminRevoke");
    default:
      return source;
  }
}

function lotLabel(source: string): string {
  switch (source) {
    case "plan_grant":
      return i18n.t("billing.lotPlanGrant");
    case "admin_grant":
      return i18n.t("billing.lotAdminGrant");
    case "overdraft":
      return i18n.t("billing.lotOverdraft");
    default:
      return source;
  }
}
