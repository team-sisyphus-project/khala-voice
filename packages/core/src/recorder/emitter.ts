/** 최소한의 타입 있는 이벤트 에미터. 의존성을 늘리지 않으려고 직접 둔다. */

export type Listener<T> = (payload: T) => void;

export class Emitter<Events> {
  #listeners = new Map<keyof Events, Set<Listener<never>>>();


  on<K extends keyof Events>(event: K, listener: Listener<Events[K]>): () => void {
    let set = this.#listeners.get(event);
    if (!set) {
      set = new Set();
      this.#listeners.set(event, set);
    }
    set.add(listener as Listener<never>);
    return () => this.off(event, listener);
  }

  off<K extends keyof Events>(event: K, listener: Listener<Events[K]>): void {
    this.#listeners.get(event)?.delete(listener as Listener<never>);
  }

  emit<K extends keyof Events>(event: K, payload: Events[K]): void {
    const set = this.#listeners.get(event);
    if (!set) return;

    // 리스너 하나가 던져도 나머지는 계속 받아야 한다
    for (const listener of [...set]) {
      try {
        (listener as Listener<Events[K]>)(payload);
      } catch (error) {
        console.error("[Emitter] 리스너 오류:", error);
      }
    }
  }

  removeAll(): void {
    this.#listeners.clear();
  }
}
