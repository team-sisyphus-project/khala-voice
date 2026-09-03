import { useCallback, useEffect, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { api } from "@/lib/api";
import { Notice } from "@/components/ui";
import { Button, Icon, Row } from "@/ui";
import type { KhalaStatus, MCPToken } from "@core/api";

/**
 * Integrations — sending to Khala, reading from outside.
 *
 * **Two things pointing in opposite directions.** Crammed into one card, "my
 * token" and "their token" mix and it's unclear what revoking cuts off. So the
 * cards are split.
 *
 * Design: `docs/15-mcp-khala.md`.
 */
export function IntegrationsSection() {
  return (
    <>
      <KhalaCard />
      <MCPCard />
    </>
  );
}

/** Us → Khala. Connect via OAuth and send meetings to the inbox. */
function KhalaCard() {
  const { t } = useTranslation();
  const [status, setStatus] = useState<KhalaStatus | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    void api
      .khalaStatus()
      .then(setStatus)
      .catch(() => setStatus(null));
  }, []);

  useEffect(load, [load]);

  // If the server turned it off, remove it from the screen entirely — never show something that fails when pressed
  if (!status?.enabled) return null;

  async function disconnect() {
    setBusy(true);

    try {
      await api.khalaDisconnect();
      load();
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="vr-settings-subgroup">
      <h3 className="vr-settings-subgroup__title">{t("integrations.khalaTitle")}</h3>
      {status.connected ? (
        <>
          <Row
            title={t("integrations.connected")}
            meta={status.inbox?.name ? t("integrations.inboxMeta", { name: status.inbox.name }) : undefined}
          />
          <p className="vr-note vr-note--small">
            <Trans t={t} i18nKey="integrations.connectedNote" components={{ strong: <strong /> }} />
          </p>
          <Button variant="secondary" onClick={() => void disconnect()} pending={busy}>
            {t("integrations.disconnect")}
          </Button>
        </>
      ) : (
        <>
          <p className="vr-note vr-note--small">
            {t("integrations.connectNote")}
          </p>
          {/* An OAuth round trip — a real navigation, not the SPA router */}
          <a className="mobile-button mobile-button--primary mobile-button--full" href="/khala/connect">
            {t("integrations.connect")}
          </a>
        </>
      )}
    </div>
  );
}

/** Them → us. Tokens external AIs use to read the archive. */
function MCPCard() {
  const { t } = useTranslation();
  const [tokens, setTokens] = useState<MCPToken[] | null>(null);
  const [issued, setIssued] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => {
    void api
      .mcpTokens()
      .then((r) => setTokens(r.tokens))
      .catch(() => setTokens([]));
  }, []);

  useEffect(load, [load]);

  async function create() {
    setBusy(true);
    setError(null);

    try {
      const token = await api.createMCPToken({ name: t("integrations.tokenName") });
      // The plaintext is visible **only now**. Once off this screen it can't be given again.
      setIssued(token.token);
      load();
    } catch (e) {
      setError(e instanceof Error ? e.message : t("integrations.createError"));
    } finally {
      setBusy(false);
    }
  }

  async function revoke(id: string) {
    await api.revokeMCPToken(id);
    load();
  }

  return (
    <div className="vr-settings-subgroup">
      <h3 className="vr-settings-subgroup__title">{t("integrations.mcpTitle")}</h3>
      <p className="vr-note vr-note--small">
        <Trans t={t} i18nKey="integrations.mcpNote" components={{ strong: <strong /> }} />
      </p>

      {issued && (
        <Notice kind="warn" icon="warning" title={t("integrations.issuedTitle")}>
          <code className="vr-token-plain">{issued}</code>
          <p className="vr-note vr-note--small">
            {t("integrations.issuedNote")}
          </p>
        </Notice>
      )}

      {tokens?.map((token) => (
        <Row
          key={token.id}
          title={token.name}
          meta={`${token.token_prefix}… · ${token.last_used_at ? t("integrations.used") : t("integrations.unused")}`}
          trailing={
            <button
              type="button"
              className="mobile-button mobile-button--ghost mobile-button--fit"
              onClick={() => void revoke(token.id)}
              aria-label={t("integrations.revokeAria", { name: token.name })}
            >
              <Icon name="close" />
            </button>
          }
        />
      ))}

      {error && <Notice kind="error" icon="error">{error}</Notice>}

      <Button variant="secondary" icon="add" onClick={() => void create()} pending={busy}>
        {t("integrations.createToken")}
      </Button>
    </div>
  );
}
