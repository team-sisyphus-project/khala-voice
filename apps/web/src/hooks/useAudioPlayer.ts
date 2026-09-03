import { useCallback, useEffect, useRef, useState } from "react";

/**
 * The unified audio player.
 *
 * **Source: sisyphus** `assets/webapp/meeting-recorder.js` 2960–3280.
 *
 * ## There is only one player
 *
 * An `<audio>` per session means two playing at once.
 * Keep one and swap its source.
 *
 * ## The webm duration bug
 *
 * webm produced by MediaRecorder reports `duration` as `Infinity` — being
 * meant for streaming, it doesn't write a length into the header. Seeking to
 * the end once makes the browser compute the real length. Same treatment as
 * sisyphus's `fixAudioDuration`.
 */
export interface AudioPlayerState {
  sessionId: string | null;
  playing: boolean;
  currentMs: number;
  durationMs: number;
}

export interface AudioPlayer extends AudioPlayerState {
  /** Play this session. Calling again with the same session toggles. */
  play: (sessionId: string, url: string, startMs?: number) => void;
  /** Move the position within the currently playing source. */
  seek: (ms: number) => void;
  toggle: () => void;
  stop: () => void;
}

export function useAudioPlayer(): AudioPlayer {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const urlRef = useRef<string | null>(null);

  const [state, setState] = useState<AudioPlayerState>({
    sessionId: null,
    playing: false,
    currentMs: 0,
    durationMs: 0,
  });

  const ensureAudio = useCallback((): HTMLAudioElement => {
    if (audioRef.current) return audioRef.current;

    const audio = new Audio();
    audio.preload = "metadata";

    audio.addEventListener("timeupdate", () => {
      setState((prev) => ({ ...prev, currentMs: audio.currentTime * 1000 }));
    });

    audio.addEventListener("loadedmetadata", () => {
      // If Infinity, seek to the end to make the browser compute the length
      if (!Number.isFinite(audio.duration)) {
        const onSeeked = () => {
          audio.removeEventListener("seeked", onSeeked);
          audio.currentTime = 0;
          setState((prev) => ({ ...prev, durationMs: audio.duration * 1000 }));
        };
        audio.addEventListener("seeked", onSeeked);
        audio.currentTime = 1e101;
      } else {
        setState((prev) => ({ ...prev, durationMs: audio.duration * 1000 }));
      }
    });

    audio.addEventListener("play", () => setState((p) => ({ ...p, playing: true })));
    audio.addEventListener("pause", () => setState((p) => ({ ...p, playing: false })));
    audio.addEventListener("ended", () =>
      setState((p) => ({ ...p, playing: false, currentMs: 0 })),
    );

    audioRef.current = audio;
    return audio;
  }, []);

  const play = useCallback(
    (sessionId: string, url: string, startMs = 0) => {
      const audio = ensureAudio();
      const sameSource = urlRef.current === url;

      if (!sameSource) {
        urlRef.current = url;
        audio.src = url;
        setState((prev) => ({ ...prev, sessionId, currentMs: startMs, durationMs: 0 }));
      } else if (state.playing && startMs === 0) {
        // Pressing the same session again toggles
        audio.pause();
        return;
      }

      const start = () => {
        if (startMs > 0) audio.currentTime = startMs / 1000;
        void audio.play().catch(() => {
          // Autoplay was blocked or the source failed to load. Pass silently.
        });
      };

      if (sameSource && audio.readyState >= 1) start();
      else audio.addEventListener("loadeddata", start, { once: true });

      setState((prev) => ({ ...prev, sessionId }));
    },
    [ensureAudio, state.playing],
  );

  const seek = useCallback((ms: number) => {
    const audio = audioRef.current;
    if (!audio) return;
    audio.currentTime = ms / 1000;
  }, []);

  const toggle = useCallback(() => {
    const audio = audioRef.current;
    if (!audio || !urlRef.current) return;
    if (audio.paused) void audio.play().catch(() => {});
    else audio.pause();
  }, []);

  const stop = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;
    audio.pause();
    audio.currentTime = 0;
    setState({ sessionId: null, playing: false, currentMs: 0, durationMs: 0 });
    urlRef.current = null;
  }, []);

  useEffect(() => {
    return () => {
      audioRef.current?.pause();
      audioRef.current = null;
    };
  }, []);

  return { ...state, play, seek, toggle, stop };
}
