import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { Notice } from "@/components/ui";
import { Button, Icon, Sheet } from "@/ui";
import type { KhalaInbox, Meeting } from "@core/api";

/**
 * 회의를 칼라 인박스로 보낸다.
 *
 * **요약이 본문이고 전사 원문이 첨부다. 오디오는 보내지 않는다** —
 * 목소리 자체가 개인정보라, 회의록을 공유하는 것과 음성 파일을 남의 인박스에
 * 넣는 것은 다른 일이다 (`docs/15-mcp-khala.md`).
 *
 * Reviewer 만 보낼 수 있다. 화면에서 막는 것은 편의일 뿐이고 **서버가 다시
 * 판정한다** — Contributor 가 이 시트를 열어도 발송은 거절된다.
 */
export function KhalaSendSheet({
  meeting,
  onClose,
}: {
  meeting: Meeting;
  onClose: () => void;
}) {
  const [inboxes, setInboxes] = useState<KhalaInbox[] | null>(null);
  const [recipient, setRecipient] = useState<string>("");
  const [attach, setAttach] = useState(true);
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void api
      .khalaInboxes()
      .then((r) => {
        const usable = r.inboxes.filter((i) => i.code);
        setInboxes(usable);

        // 하나뿐이면 고를 것이 없다. 미리 골라 둔다.
        if (usable.length === 1 && usable[0]?.code) setRecipient(usable[0].code);
      })
      .catch((e: unknown) => {
        setInboxes([]);
        setError(e instanceof Error ? e.message : "인박스를 불러오지 못했습니다");
      });
  }, []);

  async function send() {
    setSending(true);
    setError(null);

    try {
      await api.sendMeetingToKhala(meeting.id, {
        recipient_inbox_code: recipient,
        attach_transcript: attach,
      });

      setSent(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : "보내지 못했습니다");
    } finally {
      setSending(false);
    }
  }

  return (
    <Sheet title="칼라로 보내기" onClose={onClose}>
      <div className="vr-filter">
        {sent ? (
          <>
            <Notice kind="ok" icon="check_circle" title="보냈습니다">
              칼라 인박스에서 확인하세요.
            </Notice>
            <Button full onClick={onClose}>
              닫기
            </Button>
          </>
        ) : (
          <>
            <div className="vr-filter__group">
              <span className="vr-filter__label">받는 인박스</span>

              {inboxes === null && <p className="vr-note vr-note--small">불러오는 중…</p>}

              {inboxes?.length === 0 && (
                <p className="vr-note vr-note--small">
                  보낼 수 있는 인박스가 없습니다. 칼라에서 인박스를 먼저 만드세요.
                </p>
              )}

              {inboxes && inboxes.length > 0 && (
                <select
                  className="mobile-field__input"
                  value={recipient}
                  onChange={(e) => setRecipient(e.target.value)}
                  aria-label="받는 인박스"
                >
                  <option value="">고르지 않음</option>
                  {inboxes.map((inbox) => (
                    <option key={inbox.code} value={inbox.code ?? ""}>
                      {inbox.name || inbox.code}
                    </option>
                  ))}
                </select>
              )}
            </div>

            <button
              type="button"
              className="vr-check-row"
              onClick={() => setAttach(!attach)}
              aria-pressed={attach}
            >
              <Icon name={attach ? "check_box" : "check_box_outline_blank"} />
              <span>
                전사 원문 첨부
                <span className="vr-note vr-note--small">끄면 요약만 보냅니다</span>
              </span>
            </button>

            <p className="vr-note vr-note--small">
              본문은 <strong>요약</strong>입니다. 오디오는 보내지 않습니다 —
              음성이 필요하면 공유 링크를 쓰세요.
            </p>

            {error && (
              <Notice kind="error" icon="error">
                {error}
              </Notice>
            )}

            <Button
              full
              icon="share"
              disabled={!recipient}
              pending={sending}
              loadingLabel="보내는 중"
              onClick={() => void send()}
            >
              보내기
            </Button>
          </>
        )}
      </div>
    </Sheet>
  );
}
