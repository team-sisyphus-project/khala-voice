/**
 * PWA registration and the install prompt.
 *
 * ## The service worker registers after the app is up
 *
 * Never let it compete with painting the first screen. A late record button is
 * far worse than a missing offline cache.
 *
 * ## Not registered during development
 *
 * With assets constantly changing under `vite build --watch`, a service worker
 * in the middle burns time on "I fixed it but nothing changed".
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
   * When a deploy changes the asset hashes, a tab holding the old `index.html`
   * requests dead files — the screen goes completely blank. The service worker
   * reports when it sees a 404, and here we reload **exactly once**.
   *
   * Why only once: if it's still a 404 after reloading (the server really lost
   * the file), that's an infinite reload loop. Worse than a blank screen.
   */
  let reloaded = false;

  navigator.serviceWorker.addEventListener("message", (event) => {
    if (event.data?.type !== "vr:stale-shell" || reloaded) return;

    reloaded = true;
    window.location.reload();
  });

  window.addEventListener("load", () => {
    void navigator.serviceWorker.register("/sw.js", { scope: "/" }).catch(() => {
      // Registration failures pass silently. The app works fully without a service worker.
    });
  });
}

export function watchInstallPrompt(): () => void {
  const onPrompt = (event: Event) => {
    // Suppress the browser's default banner and show ours at the right moment
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

/** Show the install prompt. `false` if already used or unavailable. */
export async function promptInstall(): Promise<boolean> {
  if (!deferred) return false;

  const prompt = deferred;
  // The prompt is single-use. Clear it first to prevent a second call.
  deferred = null;
  listeners.forEach((fn) => fn(false));

  await prompt.prompt();
  const { outcome } = await prompt.userChoice;

  return outcome === "accepted";
}

/** Already running from the home screen? iOS keeps its own `standalone` flag. */
export function isStandalone(): boolean {
  return (
    window.matchMedia("(display-mode: standalone)").matches ||
    (window.navigator as { standalone?: boolean }).standalone === true
  );
}
