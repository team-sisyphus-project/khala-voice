import { useCallback, useEffect, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { api } from "@/lib/api";
import { Notice } from "@/components/ui";
import { Button, Icon, Row } from "@/ui";
import type { KhalaStatus, MCPToken } from "@core/api";

/**
 * 연동 — 칼라로 보내기, 외부에서 읽기.
 *
 * **방향이 반대인 두 가지다.** 한 카드에 몰면 "내 토큰"과 "남의 토큰"이 섞여
 * 무엇을 취소하면 무엇이 끊기는지 알 수 없다. 그래서 카드를 나눈다.
 *
 * 설계는 `docs/15-mcp-khala.md`.
 */
export function IntegrationsSection() {
  return (
    <>
      <KhalaCard />
      <MCPCard />
    </>
  );
}

/** 우리 → 칼라. OAuth 로 연결하고, 회의를 인박스로 보낸다. */
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

  // 서버가 껐으면 화면에서 아예 지운다 — 눌러도 안 되는 것을 두지 않는다
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
          {/* OAuth 왕복이라 SPA 라우터가 아니라 실제 이동이다 */}
          <a className="mobile-button mobile-button--primary mobile-button--full" href="/khala/connect">
            {t("integrations.connect")}
          </a>
        </>
      )}
    </div>
  );
}

/** 남 → 우리. 외부 AI 가 아카이브를 읽는 토큰. */
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
      // 평문은 **지금만** 볼 수 있다. 화면을 벗어나면 다시 못 준다.
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
