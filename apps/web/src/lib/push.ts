import { api } from "@/lib/api";
import i18n from "@/i18n";

/**
 * Web push subscriptions.
 *
 * Transcription and summarization take minutes. Completion must be announced
 * even after the screen is closed.
 *
 * ## Permission is requested only on a user press
 *
 * Asking for notification permission the moment the page loads gets mostly
 * denials. Once denied, the browser never asks again — it can't be undone.
 */

export type PushState = "unsupported" | "denied" | "off" | "on";

export async function pushState(): Promise<PushState> {
  if (!supported()) return "unsupported";
  if (Notification.permission === "denied") return "denied";

  const registration = await navigator.serviceWorker.getRegistration();
  const subscription = await registration?.pushManager.getSubscription();

  return subscription ? "on" : "off";
}

/** Subscribe. On failure, returns the reason as a string. */
export async function enablePush(): Promise<{ ok: true } | { ok: false; reason: string }> {
  if (!supported()) return { ok: false, reason: i18n.t("push.unsupported") };

  const status = await api.pushStatus();

  if (!status.enabled || !status.public_key) {
    return { ok: false, reason: i18n.t("push.notConfigured") };
  }

  const permission = await Notification.requestPermission();
  if (permission !== "granted") {
    return { ok: false, reason: i18n.t("push.permissionRequired") };
  }

  const registration = await navigator.serviceWorker.ready;

  const subscription = await registration.pushManager.subscribe({
    // Browsers reject subscriptions that silently receive data without notifications
    userVisibleOnly: true,
    applicationServerKey: urlBase64ToUint8Array(status.public_key),
  });

  await api.subscribePush(subscription.toJSON());
  return { ok: true };
}

export async function disablePush(): Promise<void> {
  const registration = await navigator.serviceWorker.getRegistration();
  const subscription = await registration?.pushManager.getSubscription();
  if (!subscription) return;

  // Delete on the server first. Unsubscribing only in the browser leaves the server pushing to a dead subscription.
  await api.unsubscribePush(subscription.endpoint).catch(() => {});
  await subscription.unsubscribe();
}

function supported(): boolean {
  return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
}

/**
 * The VAPID public key is a base64url string. `subscribe` takes a byte array.
 *
 * Built with an explicit `ArrayBuffer` — since TS 5.7, `Uint8Array` carries
 * its buffer type as a generic and doesn't line up with `BufferSource` directly.
 */
function urlBase64ToUint8Array(base64: string): Uint8Array<ArrayBuffer> {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4);
  const normalized = (base64 + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(normalized);

  const output = new Uint8Array(new ArrayBuffer(raw.length));
  for (let i = 0; i < raw.length; i += 1) output[i] = raw.charCodeAt(i);

  return output;
}
