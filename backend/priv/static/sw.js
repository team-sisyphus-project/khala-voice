/**
 * 서비스 워커.
 *
 * ## 이 앱에서 서비스 워커가 위험한 이유
 *
 * 녹음 앱이다. 잘못 캐시하면 **회의가 통째로 날아간다.**
 * 그래서 원칙을 좁게 잡는다.
 *
 * 1. **API 는 절대 건드리지 않는다.** 인증이 걸린 응답을 캐시하면
 *    로그아웃한 뒤에도 남의 회의록이 보일 수 있다. `/api/` 는 통째로 통과시킨다.
 * 2. **업로드(PUT)는 건드리지 않는다.** S3 presigned PUT 이 서비스 워커를
 *    거치면 서명이 어긋나거나 큰 바디가 메모리에 얹힌다.
 * 3. **해시가 붙은 자산만 캐시 우선.** `app-a1b2c3.js` 처럼 이름에 내용이
 *    박힌 것만이다. 이름이 같은데 내용이 바뀌는 파일을 캐시하면
 *    사용자가 옛 코드에 갇힌다.
 * 4. **셸은 네트워크 우선.** 새 배포를 즉시 받는다. 오프라인일 때만 캐시로 떨어진다.
 *
 * ## 오프라인에서 녹음은 계속된다
 *
 * 녹음 자체는 브라우저 안에서 일어나고 업로드 큐가 IndexedDB 에 쌓인다
 * (`packages/core/upload`). 서비스 워커는 그 큐를 대신 처리하지 않는다 —
 * 앱이 떠 있을 때 큐가 스스로 재시도한다.
 */

// 브랜드·아이콘·앱 껍데기가 바뀌면 올린다. 올리지 않으면 설치된 기기가
// 옛 index.html(옛 이름·옛 아이콘)을 계속 띄운다.
const VERSION = "v2";
const SHELL_CACHE = `vr-shell-${VERSION}`;
const ASSET_CACHE = `vr-assets-${VERSION}`;

/** 오프라인에서도 앱이 뜨려면 필요한 최소한. */
const SHELL = ["/app/meetings", "/manifest.webmanifest", "/images/icon-192.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL_CACHE)
      // 하나가 실패해도 설치를 막지 않는다 — 셸 캐시는 있으면 좋은 것이지 필수가 아니다
      .then((cache) => Promise.allSettled(SHELL.map((url) => cache.add(url))))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => key.startsWith("vr-") && key !== SHELL_CACHE && key !== ASSET_CACHE)
            .map((key) => caches.delete(key)),
        ),
      )
      .then(() => self.clients.claim()),
  );
});

/** 이름에 내용 해시가 박힌 자산인가. 그런 것만 영구 캐시해도 안전하다. */
function isHashedAsset(url) {
  return /\/app\/assets\/.+-[A-Za-z0-9_-]{8,}\.(js|css|woff2?)$/.test(url.pathname);
}

function isAppShell(request, url) {
  return request.mode === "navigate" && url.pathname.startsWith("/app");
}

self.addEventListener("fetch", (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // 다른 출처(S3 업로드·폰트)는 그대로 둔다
  if (url.origin !== self.location.origin) return;

  // GET 이 아니면 손대지 않는다 — 업로드·저장 요청을 가로채면 안 된다
  if (request.method !== "GET") return;

  // 인증이 걸린 응답은 캐시하지 않는다.
  // 공유 링크(/api/public)도 마찬가지다 — 폐기된 링크의 회의록이 남으면 안 된다.
  if (url.pathname.startsWith("/api/")) return;

  if (isHashedAsset(url)) {
    event.respondWith(cacheFirst(request));
    return;
  }

  if (isAppShell(request, url)) {
    event.respondWith(networkFirst(request));
  }
});

async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;

  let response;

  try {
    response = await fetch(request);
  } catch (error) {
    // 네트워크가 끊겼다. 여기서 그냥 던지면 `respondWith` 가 네트워크 오류를
    // 돌려주고 **앱이 빈 화면이 된다.** 캐시에도 없으면 던지는 수밖에 없지만,
    // 최소한 한 번은 캐시를 다시 뒤진다 (다른 탭이 그 사이 받아 뒀을 수 있다).
    const late = await caches.match(request);
    if (late) return late;
    throw error;
  }

  if (response.ok) {
    const cache = await caches.open(ASSET_CACHE);
    cache.put(request, response.clone());
    return response;
  }

  // 해시 자산이 404 다 = 클라이언트가 **옛 index.html** 을 들고 있다는 뜻이다
  // (배포로 해시가 바뀌었다). 이걸 그대로 두면 화면이 통째로 비어 버린다.
  // 열려 있는 탭에 알려 새 껍데기를 받게 한다.
  if (response.status === 404) {
    await notifyStale();
  }

  return response;
}

/**
 * 배포 시차를 탭에 알린다.
 *
 * 해시 자산이 사라졌다는 건 이 탭이 옛 `index.html` 로 떠 있다는 뜻이다.
 * 새로고침해야 새 자산 이름을 알 수 있다 — 사용자가 볼 수 있는 것은 빈 화면뿐이라
 * 스스로 고치게 둘 수 없다.
 */
async function notifyStale() {
  const clients = await self.clients.matchAll({ type: "window" });

  for (const client of clients) {
    client.postMessage({ type: "vr:stale-shell" });
  }
}

async function networkFirst(request) {
  try {
    const response = await fetch(request);

    if (response.ok) {
      const cache = await caches.open(SHELL_CACHE);
      cache.put(request, response.clone());
    }

    return response;
  } catch (error) {
    const cached = (await caches.match(request)) || (await caches.match("/app/meetings"));
    if (cached) return cached;
    throw error;
  }
}

// ── 푸시 ─────────────────────────────────────────────────

self.addEventListener("push", (event) => {
  if (!event.data) return;

  let payload;
  try {
    payload = event.data.json();
  } catch {
    payload = { title: "Voice Recording", body: event.data.text() };
  }

  event.waitUntil(
    self.registration.showNotification(payload.title || "Voice Recording", {
      body: payload.body || "",
      icon: "/images/icon-192.png",
      badge: "/images/icon-192.png",
      // 같은 회의의 알림이 쌓이지 않게 한다
      tag: payload.tag || "vr",
      data: { url: payload.url || "/app/meetings" },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = event.notification.data?.url || "/app/meetings";

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      // 이미 열린 탭이 있으면 그리로 보낸다. 탭을 계속 늘리지 않는다.
      for (const client of clients) {
        if (client.url.includes("/app") && "focus" in client) {
          client.navigate(target);
          return client.focus();
        }
      }

      return self.clients.openWindow(target);
    }),
  );
});
