import { useCallback, useEffect, useRef, useState } from "react";

/**
 * 통합 오디오 플레이어.
 *
 * **출처: sisyphus** `assets/webapp/meeting-recorder.js` 2960~3280.
 *
 * ## 플레이어는 하나뿐이다
 *
 * 세션마다 `<audio>` 를 두면 두 개가 동시에 울린다.
 * 하나만 두고 소스를 갈아끼운다.
 *
 * ## webm duration 버그
 *
 * MediaRecorder 가 만든 webm 은 `duration` 이 `Infinity` 로 나온다.
 * 스트리밍용으로 헤더에 길이를 안 적기 때문이다. 끝으로 한 번 seek 하면
 * 브라우저가 실제 길이를 계산한다. sisyphus 의 `fixAudioDuration` 과 같은 처리다.
 */
export interface AudioPlayerState {
  sessionId: string | null;
  playing: boolean;
  currentMs: number;
  durationMs: number;
}

export interface AudioPlayer extends AudioPlayerState {
  /** 이 세션을 재생한다. 같은 세션을 다시 부르면 토글된다. */
  play: (sessionId: string, url: string, startMs?: number) => void;
  /** 현재 재생 중인 소스에서 위치만 옮긴다. */
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
      // Infinity 면 끝으로 seek 해 브라우저가 길이를 계산하게 한다
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
        // 같은 세션을 다시 누르면 토글
        audio.pause();
        return;
      }

      const start = () => {
        if (startMs > 0) audio.currentTime = startMs / 1000;
        void audio.play().catch(() => {
          // 자동 재생이 막혔거나 소스를 못 읽었다. 조용히 넘어간다.
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
