import { useCallback, useEffect, useState } from "react";
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
      <h3 className="vr-settings-subgroup__title">칼라</h3>
      {status.connected ? (
        <>
          <Row
            title="연결됨"
            meta={status.inbox?.name ? `보내는 인박스 · ${status.inbox.name}` : undefined}
          />
          <p className="vr-note vr-note--small">
            회의 상세에서 <strong>칼라로 보내기</strong>를 누르면 요약이 본문으로,
            전사 원문이 첨부로 갑니다. 오디오는 보내지 않습니다.
          </p>
          <Button variant="secondary" onClick={() => void disconnect()} pending={busy}>
            연결 끊기
          </Button>
        </>
      ) : (
        <>
          <p className="vr-note vr-note--small">
            칼라 계정에 연결하면 회의 요약을 내 인박스로 보낼 수 있습니다.
            칼라에서 직접 로그인하고, 언제든 끊을 수 있습니다.
          </p>
          {/* OAuth 왕복이라 SPA 라우터가 아니라 실제 이동이다 */}
          <a className="mobile-button mobile-button--primary mobile-button--full" href="/khala/connect">
            칼라 연결하기
          </a>
        </>
      )}
    </div>
  );
}

/** 남 → 우리. 외부 AI 가 아카이브를 읽는 토큰. */
function MCPCard() {
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
      const token = await api.createMCPToken({ name: "읽기 토큰" });
      // 평문은 **지금만** 볼 수 있다. 화면을 벗어나면 다시 못 준다.
      setIssued(token.token);
      load();
    } catch (e) {
      setError(e instanceof Error ? e.message : "토큰을 만들지 못했습니다");
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
      <h3 className="vr-settings-subgroup__title">외부에서 읽기 (MCP)</h3>
      <p className="vr-note vr-note--small">
        다른 AI 나 도구가 내 아카이브를 <strong>읽기만</strong> 할 수 있는 토큰입니다.
        녹음·수정·오디오는 주지 않습니다.
      </p>

      {issued && (
        <Notice kind="warn" icon="warning" title="지금만 볼 수 있습니다">
          <code className="vr-token-plain">{issued}</code>
          <p className="vr-note vr-note--small">
            이 자리를 벗어나면 다시 볼 수 없습니다. 잃어버리면 새로 만드세요.
          </p>
        </Notice>
      )}

      {tokens?.map((token) => (
        <Row
          key={token.id}
          title={token.name}
          meta={`${token.token_prefix}… · ${token.last_used_at ? "사용됨" : "사용 안 함"}`}
          trailing={
            <button
              type="button"
              className="mobile-button mobile-button--ghost mobile-button--fit"
              onClick={() => void revoke(token.id)}
              aria-label={`${token.name} 취소`}
            >
              <Icon name="close" />
            </button>
          }
        />
      ))}

      {error && <Notice kind="error" icon="error">{error}</Notice>}

      <Button variant="secondary" icon="add" onClick={() => void create()} pending={busy}>
        읽기 토큰 만들기
      </Button>
    </div>
  );
}
