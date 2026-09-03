/**
 * IndexedDB upload queue.
 *
 * ## Why it exists
 *
 * A finished recording's Blob lives **only in memory**. If the tab closes or
 * the network drops in that state, an hour-long meeting vanishes wholesale.
 *
 * So the order is:
 *
 *     1. Recording ends → Blob
 *     2. Save to IndexedDB first    ← safe from this point on
 *     3. presign → S3 PUT → register with the server
 *     4. Remove from IndexedDB only on success
 *
 * **Source: sisyphus** `assets/shared/utils/pending-uploads.js` — the proven
 * order, carried over as-is.
 */

export interface PendingUpload {
  /** Session ID. Used as the key */
  id: string;
  blob: Blob;
  mimeType: string;
  durationSeconds: number;
  meetingId: string;
  startedAtUnix: number;
  retryCount: number;
  lastError: string | null;
  savedAt: number;
}

const DB_NAME = "vr-pending-uploads";
const DB_VERSION = 1;
const STORE = "recordings";

/** Past this count, automatic retries stop and the user is notified. */
export const MAX_RETRIES = 5;

export class UploadQueue {
  #dbPromise: Promise<IDBDatabase> | null = null;

  static isSupported(): boolean {
    return typeof indexedDB !== "undefined";
  }

  async #db(): Promise<IDBDatabase> {
    if (this.#dbPromise) return this.#dbPromise;

    this.#dbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);

      request.onerror = () => reject(request.error);
      request.onsuccess = () => resolve(request.result);

      request.onupgradeneeded = (event) => {
        const db = (event.target as IDBOpenDBRequest).result;
        if (!db.objectStoreNames.contains(STORE)) {
          const store = db.createObjectStore(STORE, { keyPath: "id" });
          store.createIndex("savedAt", "savedAt");
          store.createIndex("meetingId", "meetingId");
        }
      };
    });

    return this.#dbPromise;
  }

  async #tx<T>(mode: IDBTransactionMode, fn: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
    const db = await this.#db();

    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, mode);
      const request = fn(tx.objectStore(STORE));

      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      tx.onabort = () => reject(tx.error);
    });
  }

  async save(item: Omit<PendingUpload, "retryCount" | "lastError" | "savedAt">): Promise<void> {
    const record: PendingUpload = {
      ...item,
      retryCount: 0,
      lastError: null,
      savedAt: Date.now(),
    };

    await this.#tx("readwrite", (store) => store.put(record));
  }

  async get(id: string): Promise<PendingUpload | undefined> {
    return this.#tx("readonly", (store) => store.get(id));
  }

  async list(): Promise<PendingUpload[]> {
    const all = await this.#tx<PendingUpload[]>("readonly", (store) => store.getAll());
    return all.sort((a, b) => a.savedAt - b.savedAt);
  }

  /** Auto-retry candidates — those still under the limit. */
  async listRetryable(): Promise<PendingUpload[]> {
    return (await this.list()).filter((item) => item.retryCount < MAX_RETRIES);
  }

  /** Those past the limit, needing a user decision. */
  async listFailed(): Promise<PendingUpload[]> {
    return (await this.list()).filter((item) => item.retryCount >= MAX_RETRIES);
  }

  async remove(id: string): Promise<void> {
    await this.#tx("readwrite", (store) => store.delete(id));
  }

  async recordFailure(id: string, message: string): Promise<void> {
    const item = await this.get(id);
    if (!item) return;

    await this.#tx("readwrite", (store) =>
      store.put({ ...item, retryCount: item.retryCount + 1, lastError: message }),
    );
  }

  async clear(): Promise<void> {
    await this.#tx("readwrite", (store) => store.clear());
  }

  /** Total stored bytes. Used for storage warnings. */
  async totalBytes(): Promise<number> {
    return (await this.list()).reduce((sum, item) => sum + item.blob.size, 0);
  }
}
