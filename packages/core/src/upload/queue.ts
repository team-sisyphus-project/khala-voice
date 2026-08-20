/**
 * IndexedDB 업로드 대기 큐.
 *
 * ## 왜 필요한가
 *
 * 녹음이 끝난 Blob 은 **메모리에만** 있다. 이 상태에서 탭이 닫히거나
 * 네트워크가 끊기면 한 시간짜리 회의가 통째로 사라진다.
 *
 * 그래서 순서를 이렇게 잡는다.
 *
 *     1. 녹음 종료 → Blob
 *     2. IndexedDB 에 먼저 저장    ← 여기부터는 안전하다
 *     3. presign → S3 PUT → 서버 등록
 *     4. 성공했을 때만 IndexedDB 에서 제거
 *
 * **출처: sisyphus** `assets/shared/utils/pending-uploads.js` — 검증된 순서를 그대로 가져왔다.
 */

export interface PendingUpload {
  /** 세션 ID. 키로 쓴다 */
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

/** 이 횟수를 넘으면 자동 재시도를 멈추고 사용자에게 알린다. */
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

  /** 자동 재시도 대상 — 아직 한도를 넘지 않은 것. */
  async listRetryable(): Promise<PendingUpload[]> {
    return (await this.list()).filter((item) => item.retryCount < MAX_RETRIES);
  }

  /** 한도를 넘어 사용자 판단이 필요한 것. */
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

  /** 저장된 총 바이트. 용량 경고에 쓴다. */
  async totalBytes(): Promise<number> {
    return (await this.list()).reduce((sum, item) => sum + item.blob.size, 0);
  }
}
