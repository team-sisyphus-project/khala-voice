import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
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
  const { t } = useTranslation();
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
      <p className="vr-note vr-note--small">
        {t("notification.unsupported")}
      </p>
    );
  }

  return (
    <>
      {/* 카드 안의 간격은 `mobile-section__body` 가 정한다 (8px). 여기서 따로 주지 않는다. */}
      <div className="vr-toggle-row">
        <div className="vr-toggle-row__main">
          <div className="vr-toggle-row__title">{t("notification.title")}</div>
          <p className="vr-note vr-note--small">
            {t("notification.desc")}
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
                setError(e instanceof Error ? e.message : t("notification.error"));
              })
              .finally(() => setBusy(false));
          }}
        >
          {state === "on" ? t("notification.on") : t("notification.off")}
        </button>
      </div>

      {state === "denied" && (
        <Notice kind="warn" icon="notifications_off">
          {t("notification.blocked")}
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
