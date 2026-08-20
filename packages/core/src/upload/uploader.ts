import type { ApiClient } from "../api/client";
import { MAX_RETRIES, UploadQueue, type PendingUpload } from "./queue";

export interface UploaderEvents {
  progress: { id: string; done: number; total: number };
  uploaded: { id: string };
  failed: { id: string; message: string; willRetry: boolean };
  queuechange: { pending: number; failed: number };
}

/**
 * 업로드 실행기.
 *
 * ## 순차 처리
 *
 * 한 번에 하나만 올린다. 동시에 여러 개를 올리면 모바일 회선에서
 * 서로 대역폭을 뺏어 전부 느려지고 타임아웃이 겹친다.
 *
 * ## 자동 재개
 *
 * `online` 이벤트와 앱 시작 시점에 큐를 훑는다.
 * 비행기 모드에서 녹음한 것이 연결 복구 후 저절로 올라간다.
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
        console.error("[Uploader] 리스너 오류:", error);
      }
    }
  }

  /** 온라인 복귀 감시를 켠다. 앱 시작 시 한 번 부른다. */
  start(): void {
    if (this.#onlineHandler) return;

    this.#onlineHandler = () => {
      // 연결이 막 붙은 직후에는 불안정하다. 조금 기다린다.
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
   * 녹음 결과를 큐에 넣고 바로 올려본다.
   *
   * **저장이 먼저다.** 저장에 실패해도 업로드는 시도하지만,
   * 그때는 실패 시 복구할 수단이 없다는 뜻이므로 경고를 남긴다.
   */
  async enqueue(item: Omit<PendingUpload, "retryCount" | "lastError" | "savedAt">): Promise<void> {
    if (UploadQueue.isSupported()) {
      try {
        await this.queue.save(item);
      } catch (error) {
        console.error("[Uploader] 로컬 저장 실패 — 업로드가 실패하면 복구할 수 없습니다:", error);
      }
    }

    await this.#notifyQueueChange();
    void this.flush();
  }

  /** 큐를 순차로 비운다. 이미 돌고 있으면 아무것도 하지 않는다. */
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

  /** 실패 한도를 넘긴 항목을 사용자 요청으로 다시 시도한다. */
  async retryFailed(): Promise<void> {
    for (const item of await this.queue.listFailed()) {
      await this.queue.remove(item.id);
      await this.queue.save(item); // retryCount 를 0 으로 되돌린다
    }
    await this.flush();
  }

  async discardFailed(): Promise<void> {
    for (const item of await this.queue.listFailed()) {
      await this.queue.remove(item.id);
    }
    await this.#notifyQueueChange();
  }

  // ── 내부 ───────────────────────────────────────────────

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
   * S3 에 직접 PUT.
   *
   * `fetch` 대신 `XMLHttpRequest` 를 쓴다 — 업로드 진행률을 알 수 있는 건
   * 아직 XHR 뿐이다. 수십 MB 를 올리는 동안 진행률이 없으면 사용자는 멈춘 줄 안다.
   */
  #putToStorage(url: string, item: PendingUpload, contentType: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open("PUT", url, true);
      // presign 서명에 포함된 값과 정확히 같아야 한다. 다르면 S3 가 거부한다.
      xhr.setRequestHeader("Content-Type", contentType);

      xhr.upload.onprogress = (event) => {
        if (event.lengthComputable) {
          this.#emit("progress", { id: item.id, done: event.loaded, total: event.total });
        }
      };

      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) resolve();
        else reject(new Error(`스토리지 업로드 실패 (${xhr.status})`));
      };

      xhr.onerror = () => reject(new Error("네트워크 오류"));
      xhr.ontimeout = () => reject(new Error("업로드 시간 초과"));
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
