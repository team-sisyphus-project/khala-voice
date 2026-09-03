/**
 * Service worker.
 *
 * ## Why a service worker is dangerous in this app
 *
 * This is a recording app. Cache the wrong thing and **an entire meeting is
 * lost.** So the rules are kept narrow.
 *
 * 1. **Never touch the API.** Caching an authenticated response could show
 *    someone else's meeting notes after logout. `/api/` passes through wholesale.
 * 2. **Never touch uploads (PUT).** An S3 presigned PUT going through the
 *    service worker breaks the signature or piles a huge body into memory.
 * 3. **Cache-first only for hashed assets.** Only names with the content baked
 *    in, like `app-a1b2c3.js`. Caching a file whose name stays the same while
 *    its content changes traps users on old code.
 * 4. **Network-first for the shell.** New deploys land immediately. We fall
 *    back to cache only while offline.
 *
 * ## Recording keeps going offline
 *
 * Recording itself happens in the browser and the upload queue accumulates in
 * IndexedDB (`packages/core/upload`). The service worker does not process that
 * queue — the queue retries on its own while the app is open.
 */

// Bump when the brand, icons, or app shell change. Otherwise installed
// devices keep showing the old index.html (old name, old icons).
const VERSION = "v2";
const SHELL_CACHE = `vr-shell-${VERSION}`;
const ASSET_CACHE = `vr-assets-${VERSION}`;

/** The bare minimum for the app to open offline. */
const SHELL = ["/app/meetings", "/manifest.webmanifest", "/images/icon-192.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL_CACHE)
      // One failure must not block install — the shell cache is nice to have, not required
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

/** Is this an asset with a content hash in its name? Only those are safe to cache forever. */
function isHashedAsset(url) {
  return /\/app\/assets\/.+-[A-Za-z0-9_-]{8,}\.(js|css|woff2?)$/.test(url.pathname);
}

function isAppShell(request, url) {
  return request.mode === "navigate" && url.pathname.startsWith("/app");
}

self.addEventListener("fetch", (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // Leave other origins alone (S3 uploads, fonts)
  if (url.origin !== self.location.origin) return;

  // Only touch GET — upload/save requests must never be intercepted
  if (request.method !== "GET") return;

  // Never cache authenticated responses.
  // Same for share links (/api/public) — notes from a revoked link must not linger.
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
    // The network is down. Throwing here makes `respondWith` return a network
    // error and **the app goes blank.** If the cache misses too we have no
    // choice, but check the cache once more first (another tab may have
    // fetched it in the meantime).
    const late = await caches.match(request);
    if (late) return late;
    throw error;
  }

  if (response.ok) {
    const cache = await caches.open(ASSET_CACHE);
    cache.put(request, response.clone());
    return response;
  }

  // A hashed asset 404ing means the client is holding an **old index.html**
  // (a deploy changed the hashes). Left alone, the screen goes completely
  // blank. Tell the open tabs so they fetch the new shell.
  if (response.status === 404) {
    await notifyStale();
  }

  return response;
}

/**
 * Tell the tabs about the deploy skew.
 *
 * A vanished hashed asset means this tab is running an old `index.html`.
 * Only a refresh reveals the new asset names — and all the user can see is a
 * blank screen, so we cannot leave them to fix it themselves.
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

// ── Push ─────────────────────────────────────────────────

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
      // Keep notifications for the same meeting from piling up
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
      // If a tab is already open, send it there. Do not keep multiplying tabs.
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
