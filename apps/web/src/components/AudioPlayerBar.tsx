import { useEffect } from "react";
import { timeLabel } from "@core/domain";
import type { AudioPlayer } from "@/hooks/useAudioPlayer";
import { Icon } from "@/ui";

/**
 * 하단 고정 플레이어. 화면에 **하나만** 존재한다.
 *
 * **출처: sisyphus** — 세션마다 `<audio>` 를 두면 둘이 동시에 울린다.
 */
export function AudioPlayerBar({ player, label }: { player: AudioPlayer; label?: string }) {
  const open = player.sessionId !== null;

  // 본문이 플레이어 뒤로 숨지 않도록 아래 여백을 확보한다
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
    <div className="vr-player" role="region" aria-label="오디오 재생">
      <button
        type="button"
        className="vr-player__btn"
        onClick={player.toggle}
        aria-label={player.playing ? "일시정지" : "재생"}
      >
        <Icon name={player.playing ? "pause" : "play_arrow"} />
      </button>

      <span className="vr-player__time">{timeLabel(player.currentMs)}</span>

      <div
        className="vr-player__bar"
        role="slider"
        aria-label="재생 위치"
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
        aria-label="닫기"
      >
        <Icon name="close" />
      </button>
    </div>
  );
}
