import { useEffect, useState } from "react";
import type { ReactNode } from "react";

/**
 * Intro.
 *
 * **Source: khala** `frontend/src/components/intro/IntroScreen.tsx` — the
 * phases (logo → exit) and the once-per-session rule carried over as-is.
 *
 * What changed:
 * - No PWA resume splash. khala is a continuing-conversation app with
 *   frequent returns, but here returns often happen mid-recording, and a logo
 *   covering the screen each time would be disruptive
 * - The wordmark is drawn as text, not an image — it must follow the theme
 *
 * Children are **always mounted**, only hidden during the intro — per the
 * original's comment, swapping the whole tree blows up in StrictMode double
 * renders when React removes nodes.
 */

const SESSION_FLAG = "khala-voice.intro.seen";
const LOGO_MS = 1200;
const EXIT_MS = 420;

function shouldShow(): boolean {
  if (typeof window === "undefined") return false;

  try {
    return window.sessionStorage.getItem(SESSION_FLAG) === null;
  } catch {
    // Storage-blocked environments like private browsing. Open the app right away, no intro.
    return false;
  }
}

export function IntroScreen({ children }: { children: ReactNode }) {
  const [show, setShow] = useState(shouldShow);
  const [phase, setPhase] = useState<"logo" | "exit">("logo");

  useEffect(() => {
    if (!show) return;

    const exit = window.setTimeout(() => setPhase("exit"), LOGO_MS);
    const done = window.setTimeout(() => {
      try {
        window.sessionStorage.setItem(SESSION_FLAG, "1");
      } catch {
        // Even if it can't be saved, the intro still ends
      }

      setShow(false);
    }, LOGO_MS + EXIT_MS);

    return () => {
      window.clearTimeout(exit);
      window.clearTimeout(done);
    };
  }, [show]);

  return (
    <>
      <div className="vr-intro-host" data-hidden={show ? "true" : undefined}>
        {children}
      </div>

      {show && (
        <div className={`vr-intro vr-intro--${phase}`} role="presentation" aria-hidden="true">
          <div className="vr-intro__brand">
            <img alt="" className="vr-intro__icon" src="/images/icon-512.png" />
            <p className="vr-intro__wordmark">KHALA VOICE</p>
          </div>
        </div>
      )}
    </>
  );
}
