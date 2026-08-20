import { api } from "@/lib/api";

/**
 * 웹 푸시 구독.
 *
 * 전사·요약은 몇 분씩 걸린다. 화면을 닫아도 끝났다는 것을 알려야 한다.
 *
 * ## 권한은 사용자가 누를 때만 요청한다
 *
 * 페이지가 뜨자마자 알림 권한을 물으면 대부분 거절한다. 한 번 거절하면
 * 브라우저가 다시 묻지 않으므로 되돌릴 수 없다.
 */

export type PushState = "unsupported" | "denied" | "off" | "on";

export async function pushState(): Promise<PushState> {
  if (!supported()) return "unsupported";
  if (Notification.permission === "denied") return "denied";

  const registration = await navigator.serviceWorker.getRegistration();
  const subscription = await registration?.pushManager.getSubscription();

  return subscription ? "on" : "off";
}

/** 구독한다. 실패하면 이유를 문자열로 돌려준다. */
export async function enablePush(): Promise<{ ok: true } | { ok: false; reason: string }> {
  if (!supported()) return { ok: false, reason: "이 브라우저는 알림을 지원하지 않습니다" };

  const status = await api.pushStatus();

  if (!status.enabled || !status.public_key) {
    return { ok: false, reason: "서버에 알림이 설정되지 않았습니다" };
  }

  const permission = await Notification.requestPermission();
  if (permission !== "granted") {
    return { ok: false, reason: "알림 권한이 필요합니다" };
  }

  const registration = await navigator.serviceWorker.ready;

  const subscription = await registration.pushManager.subscribe({
    // 알림 없이 조용히 데이터만 받는 구독은 브라우저가 거부한다
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

  // 서버에서 먼저 지운다. 브라우저만 해지하면 서버가 죽은 구독에 계속 보낸다.
  await api.unsubscribePush(subscription.endpoint).catch(() => {});
  await subscription.unsubscribe();
}

function supported(): boolean {
  return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
}

/**
 * VAPID 공개키는 base64url 문자열이다. `subscribe` 는 바이트 배열을 받는다.
 *
 * `ArrayBuffer` 를 명시해 만든다 — TS 5.7 부터 `Uint8Array` 가 버퍼 타입을
 * 제네릭으로 들고 있어서 `BufferSource` 와 바로 맞지 않는다.
 */
function urlBase64ToUint8Array(base64: string): Uint8Array<ArrayBuffer> {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4);
  const normalized = (base64 + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(normalized);

  const output = new Uint8Array(new ArrayBuffer(raw.length));
  for (let i = 0; i < raw.length; i += 1) output[i] = raw.charCodeAt(i);

  return output;
}
