import { useEffect } from "react";
import { useTranslation } from "react-i18next";
import { timeLabel } from "@core/domain";
import type { AudioPlayer } from "@/hooks/useAudioPlayer";
import { Icon } from "@/ui";

/**
 * The bottom-pinned player. **Only one** exists on screen.
 *
 * **Source: sisyphus** — an `<audio>` per session means two playing at once.
 */
export function AudioPlayerBar({ player, label }: { player: AudioPlayer; label?: string }) {
  const { t } = useTranslation();
  const open = player.sessionId !== null;

  // Reserve bottom space so the body doesn't hide behind the player
  useEffect(() => {
    if (!open) return;
    document.body.dataset["player"] = "open";
    return () => {
      delete document.body.dataset["player"];
    };
  }, [open]);

  if (!open) return null;

  const progress =
    player.durationMs > 0 ? Math.min(100, (player.currentMs / player.durationMs) * 100) : 0;

  return (
    <div className="vr-player" role="region" aria-label={t("player.regionAria")}>
      <button
        type="button"
        className="vr-player__btn"
        onClick={player.toggle}
        aria-label={player.playing ? t("player.pause") : t("player.play")}
      >
        <Icon name={player.playing ? "pause" : "play_arrow"} />
      </button>

      <span className="vr-player__time">{timeLabel(player.currentMs)}</span>

      <div
        className="vr-player__bar"
        role="slider"
        aria-label={t("player.seekAria")}
        aria-valuemin={0}
        aria-valuemax={Math.round(player.durationMs)}
        aria-valuenow={Math.round(player.currentMs)}
        tabIndex={0}
        onClick={(e) => {
          const rect = e.currentTarget.getBoundingClientRect();
          const ratio = (e.clientX - rect.left) / rect.width;
          player.seek(ratio * player.durationMs);
        }}
        onKeyDown={(e) => {
          if (e.key === "ArrowRight") player.seek(player.currentMs + 5000);
          if (e.key === "ArrowLeft") player.seek(Math.max(0, player.currentMs - 5000));
        }}
      >
        <div className="vr-player__fill" style={{ width: `${progress}%` }} />
      </div>

      <span className="vr-player__time">
        {player.durationMs > 0 ? timeLabel(player.durationMs) : "--:--"}
      </span>

      {label && (
        <span className="mobile-row__meta" style={{ fontSize: 12, flexShrink: 0 }}>{label}</span>
      )}

      <button
        type="button"
        className="mobile-button mobile-button--ghost mobile-button--fit"
        onClick={player.stop}
        aria-label={t("common.close")}
      >
        <Icon name="close" />
      </button>
    </div>
  );
}
