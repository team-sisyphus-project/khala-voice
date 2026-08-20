import { useCallback, useEffect, useState } from "react";
import { disablePush, enablePush, pushState } from "@/lib/push";
import type { PushState } from "@/lib/push";
import { Notice } from "@/components/ui";

/**
 * 알림 켜기/끄기.
 *
 * 전사·요약이 끝났을 때만 보낸다. 잠금화면에 회의 내용이 뜨지 않도록
 * 서버가 본문에 "끝났습니다" 까지만 담는다.
 */
export function NotificationSetting() {
  const [state, setState] = useState<PushState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(() => {
    void pushState().then(setState);
  }, []);

  useEffect(refresh, [refresh]);

  if (state === null) return null;

  if (state === "unsupported") {
    return (
      <p className="vr-note" style={{ fontSize: 12 }}>
        이 브라우저는 알림을 지원하지 않습니다.
      </p>
    );
  }

  return (
    <>
      {/* 카드 안의 간격은 `mobile-section__body` 가 정한다 (8px). 여기서 따로 주지 않는다. */}
      <div className="vr-toggle-row">
        <div className="vr-toggle-row__main">
          <div className="vr-toggle-row__title">작업 완료 알림</div>
          <p className="vr-note vr-note--small">
            전사와 요약이 끝나면 알려드립니다. 회의 내용은 알림에 담지 않습니다.
          </p>
        </div>

        <button
          className={
            state === "on" ? "mobile-button mobile-button--primary mobile-button--fit" : "mobile-button mobile-button--secondary mobile-button--fit"
          }
          aria-pressed={state === "on"}
          disabled={busy || state === "denied"}
          onClick={() => {
            setBusy(true);
            setError(null);

            const run = state === "on" ? disablePush().then(() => ({ ok: true as const })) : enablePush();

            void run
              .then((result) => {
                if (!result.ok) setError(result.reason);
                refresh();
              })
              .catch((e: unknown) => {
                setError(e instanceof Error ? e.message : "알림을 설정하지 못했습니다");
              })
              .finally(() => setBusy(false));
          }}
        >
          {state === "on" ? "켜짐" : "꺼짐"}
        </button>
      </div>

      {state === "denied" && (
        <Notice kind="warn" icon="notifications_off">
          브라우저에서 알림이 차단돼 있습니다. 주소창의 자물쇠 아이콘에서 허용으로 바꿔주세요.
          {/* 한 번 거절하면 JS 로 다시 물을 수 없다 */}
        </Notice>
      )}

      {error && (
        <Notice kind="error" icon="error">
          {error}
        </Notice>
      )}
    </>
  );
}
