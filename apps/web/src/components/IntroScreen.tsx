import { useEffect, useState } from "react";
import type { ReactNode } from "react";

/**
 * 인트로.
 *
 * **출처: khala** `frontend/src/components/intro/IntroScreen.tsx` — 단계(로고 → 퇴장)와
 * 세션당 1회 규칙을 그대로 가져왔다.
 *
 * 바꾼 것:
 * - PWA resume 스플래시를 넣지 않았다. khala 는 대화가 이어지는 앱이라 복귀가
 *   잦지만, 여기는 녹음 중 복귀가 잦고 그때마다 로고가 덮으면 방해가 된다
 * - 워드마크를 이미지가 아니라 글자로 그린다 — 테마를 따라가야 한다
 *
 * 자식은 **항상 마운트**한다. 인트로 중에만 숨긴다 — 원본 주석대로, 트리를
 * 통째로 갈아끼우면 StrictMode 이중 렌더에서 React 가 노드 제거로 터진다.
 */

const SESSION_FLAG = "khala-voice.intro.seen";
const LOGO_MS = 1200;
const EXIT_MS = 420;

function shouldShow(): boolean {
  if (typeof window === "undefined") return false;

  try {
    return window.sessionStorage.getItem(SESSION_FLAG) === null;
  } catch {
    // 시크릿 모드 등 저장소가 막힌 환경. 인트로 없이 바로 앱을 연다.
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
        // 저장 못 해도 인트로는 끝난다
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
