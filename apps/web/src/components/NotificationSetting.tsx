import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { disablePush, enablePush, pushState } from "@/lib/push";
import type { PushState } from "@/lib/push";
import { Notice } from "@/components/ui";

/**
 * Notifications on/off.
 *
 * Sent only when transcription or a summary finishes. So no meeting content
 * appears on the lock screen, the server puts nothing beyond "finished" in
 * the body.
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
      {/* Spacing inside the card is set by `mobile-section__body` (8px). None added here. */}
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
          {/* Once denied, JS can never ask again */}
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
