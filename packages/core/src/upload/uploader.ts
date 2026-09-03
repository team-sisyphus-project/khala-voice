import type { ApiClient } from "../api/client";
import { MAX_RETRIES, UploadQueue, type PendingUpload } from "./queue";

export interface UploaderEvents {
  progress: { id: string; done: number; total: number };
  uploaded: { id: string };
  failed: { id: string; message: string; willRetry: boolean };
  queuechange: { pending: number; failed: number };
}

/**
 * Upload runner.
 *
 * ## Sequential processing
 *
 * Uploads one at a time. Parallel uploads on a mobile connection steal
 * bandwidth from each other, slowing everything down and stacking timeouts.
 *
 * ## Automatic resume
 *
 * Sweeps the queue on the `online` event and at app start.
 * A recording made in airplane mode goes up by itself once connectivity
 * returns.
 */
export class Uploader {
  readonly queue = new UploadQueue();

  #api: ApiClient;
  #running = false;
  #listeners = new Map<keyof UploaderEvents, Set<(payload: never) => void>>();
  #onlineHandler: (() => void) | null = null;

  constructor(api: ApiClient) {
    this.#api = api;
  }

  on<K extends keyof UploaderEvents>(
    event: K,
    listener: (payload: UploaderEvents[K]) => void,
  ): () => void {
    let set = this.#listeners.get(event);
    if (!set) {
      set = new Set();
      this.#listeners.set(event, set);
    }
    set.add(listener as (payload: never) => void);
    return () => set!.delete(listener as (payload: never) => void);
  }

  #emit<K extends keyof UploaderEvents>(event: K, payload: UploaderEvents[K]): void {
    for (const listener of this.#listeners.get(event) ?? []) {
      try {
        (listener as (p: UploaderEvents[K]) => void)(payload);
      } catch (error) {
        console.error("[Uploader] listener error:", error);
      }
    }
  }

  /** Starts watching for connectivity return. Called once at app start. */
  start(): void {
    if (this.#onlineHandler) return;

    this.#onlineHandler = () => {
      // A freshly restored connection is flaky. Wait a moment.
      setTimeout(() => void this.flush(), 1500);
    };

    window.addEventListener("online", this.#onlineHandler);

    if (navigator.onLine) {
      setTimeout(() => void this.flush(), 1000);
    }
  }

  stop(): void {
    if (this.#onlineHandler) {
      window.removeEventListener("online", this.#onlineHandler);
      this.#onlineHandler = null;
    }
  }

  /**
   * Queues a recording result and immediately tries to upload it.
   *
   * **Saving comes first.** If saving fails, the upload is still attempted,
   * but that means there is no recovery path on failure — so a warning is
   * logged.
   */
  async enqueue(item: Omit<PendingUpload, "retryCount" | "lastError" | "savedAt">): Promise<void> {
    if (UploadQueue.isSupported()) {
      try {
        await this.queue.save(item);
      } catch (error) {
        console.error("[Uploader] local save failed — if the upload fails there is no recovery:", error);
      }
    }

    await this.#notifyQueueChange();
    void this.flush();
  }

  /** Drains the queue sequentially. Does nothing if already running. */
  async flush(): Promise<void> {
    if (this.#running || !navigator.onLine) return;
    this.#running = true;

    try {
      for (const item of await this.queue.listRetryable()) {
        await this.#upload(item);
      }
    } finally {
      this.#running = false;
      await this.#notifyQueueChange();
    }
  }

  /** Retries items past the failure limit, at the user's request. */
  async retryFailed(): Promise<void> {
    for (const item of await this.queue.listFailed()) {
      await this.queue.remove(item.id);
      await this.queue.save(item); // resets retryCount to 0
    }
    await this.flush();
  }

  async discardFailed(): Promise<void> {
    for (const item of await this.queue.listFailed()) {
      await this.queue.remove(item.id);
    }
    await this.#notifyQueueChange();
  }

  // ── Internal ───────────────────────────────────────────

  async #upload(item: PendingUpload): Promise<void> {
    try {
      const presign = await this.#api.presignUpload({
        sessionId: item.id,
        contentType: item.mimeType,
      });

      await this.#putToStorage(presign.upload_url, item, presign.content_type);

      await this.#api.registerUpload(item.id, {
        duration_seconds: item.durationSeconds,
        file_size_bytes: item.blob.size,
        mime_type: item.mimeType,
      });

      await this.queue.remove(item.id);
      this.#emit("uploaded", { id: item.id });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await this.queue.recordFailure(item.id, message);

      const updated = await this.queue.get(item.id);
      const willRetry = (updated?.retryCount ?? MAX_RETRIES) < MAX_RETRIES;

      this.#emit("failed", { id: item.id, message, willRetry });
    }
  }

  /**
   * Direct PUT to S3.
   *
   * Uses `XMLHttpRequest` instead of `fetch` — XHR is still the only way to
   * get upload progress. Without progress on a tens-of-MB upload, the user
   * assumes it froze.
   */
  #putToStorage(url: string, item: PendingUpload, contentType: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open("PUT", url, true);
      // Must exactly match the value in the presign signature. S3 rejects otherwise.
      xhr.setRequestHeader("Content-Type", contentType);

      xhr.upload.onprogress = (event) => {
        if (event.lengthComputable) {
          this.#emit("progress", { id: item.id, done: event.loaded, total: event.total });
        }
      };

      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) resolve();
        else reject(new Error(`Storage upload failed (${xhr.status})`));
      };

      xhr.onerror = () => reject(new Error("Network error"));
      xhr.ontimeout = () => reject(new Error("Upload timed out"));
      xhr.timeout = 10 * 60 * 1000;

      xhr.send(item.blob);
    });
  }

  async #notifyQueueChange(): Promise<void> {
    if (!UploadQueue.isSupported()) return;

    const [pending, failed] = await Promise.all([
      this.queue.listRetryable(),
      this.queue.listFailed(),
    ]);

    this.#emit("queuechange", { pending: pending.length, failed: failed.length });
  }
}
