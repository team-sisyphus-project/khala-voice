/**
 * PWA 등록과 설치 프롬프트.
 *
 * ## 서비스 워커는 앱이 뜬 뒤에 등록한다
 *
 * 첫 화면을 그리는 일과 경쟁시키지 않는다. 녹음 버튼이 늦게 뜨는 것이
 * 오프라인 캐시보다 훨씬 나쁘다.
 *
 * ## 개발 중에는 등록하지 않는다
 *
 * `vite build --watch` 로 자산이 계속 바뀌는데 서비스 워커가 끼면
 * "고쳤는데 안 바뀐다"에 시간을 태우게 된다.
 */

export interface InstallPrompt {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

let deferred: InstallPrompt | null = null;
const listeners = new Set<(available: boolean) => void>();

export function registerServiceWorker(): void {
  if (!("serviceWorker" in navigator)) return;
  if (import.meta.env.DEV) return;

  /**
   * 배포로 자산 해시가 바뀌면 옛 `index.html` 을 들고 있는 탭은 죽은 파일을
   * 부른다 — 화면이 통째로 빈다. 서비스 워커가 404 를 보면 알려주고, 여기서
   * **한 번만** 새로고침한다.
   *
   * 한 번으로 제한하는 이유: 새로고침해도 여전히 404 라면(서버가 실제로 그
   * 파일을 잃은 경우) 무한 새로고침이 된다. 그건 빈 화면보다 나쁘다.
   */
  let reloaded = false;

  navigator.serviceWorker.addEventListener("message", (event) => {
    if (event.data?.type !== "vr:stale-shell" || reloaded) return;

    reloaded = true;
    window.location.reload();
  });

  window.addEventListener("load", () => {
    void navigator.serviceWorker.register("/sw.js", { scope: "/" }).catch(() => {
      // 등록 실패는 조용히 넘어간다. 앱은 서비스 워커 없이도 완전히 동작한다.
    });
  });
}

export function watchInstallPrompt(): () => void {
  const onPrompt = (event: Event) => {
    // 브라우저 기본 배너를 막고 우리 화면에서 적절한 때에 띄운다
    event.preventDefault();
    deferred = event as unknown as InstallPrompt;
    listeners.forEach((fn) => fn(true));
  };

  const onInstalled = () => {
    deferred = null;
    listeners.forEach((fn) => fn(false));
  };

  window.addEventListener("beforeinstallprompt", onPrompt);
  window.addEventListener("appinstalled", onInstalled);

  return () => {
    window.removeEventListener("beforeinstallprompt", onPrompt);
    window.removeEventListener("appinstalled", onInstalled);
  };
}

export function onInstallAvailability(fn: (available: boolean) => void): () => void {
  listeners.add(fn);
  fn(deferred !== null);
  return () => listeners.delete(fn);
}

/** 설치 프롬프트를 띄운다. 이미 썼거나 없으면 `false`. */
export async function promptInstall(): Promise<boolean> {
  if (!deferred) return false;

  const prompt = deferred;
  // 프롬프트는 한 번만 쓸 수 있다. 먼저 비워 두 번 부르는 것을 막는다.
  deferred = null;
  listeners.forEach((fn) => fn(false));

  await prompt.prompt();
  const { outcome } = await prompt.userChoice;

  return outcome === "accepted";
}

/** 이미 홈 화면에서 실행 중인가. iOS 는 `standalone` 을 따로 둔다. */
export function isStandalone(): boolean {
  return (
    window.matchMedia("(display-mode: standalone)").matches ||
    (window.navigator as { standalone?: boolean }).standalone === true
  );
}
