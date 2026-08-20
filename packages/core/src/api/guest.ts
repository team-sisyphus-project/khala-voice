import type { Meeting, ShareEntry, ShareGate } from "./types";

/**
 * 게스트 전용 API 클라이언트.
 *
 * ## 왜 별도 클라이언트인가
 *
 * 게스트 자격은 `X-Guest-Token` 헤더로 간다. 쿠키를 쓰지 않는 이유는
 * (a) `:api` 파이프라인에 CSRF 방어가 없고 (b) 쿠키는 도메인 전역이라
 * "회의 하나만" 이라는 제약과 어긋나기 때문이다.
 *
 * ## 회의 id 를 보내지 않는다
 *
 * 게스트가 볼 회의는 **서버의 게스트 세션이 정한다.** 클라이언트가 회의를
 * 지정할 방법이 없으므로, 다른 회의를 가리키는 시도 자체가 불가능하다.
 */
export class GuestApiClient {
  readonly #baseUrl: string;
  #token: string | null = null;

  constructor(baseUrl = "") {
    this.#baseUrl = baseUrl.replace(/\/$/, "");
  }

  get token(): string | null {
    return this.#token;
  }

  set token(value: string | null) {
    this.#token = value;
  }

  /** 입장 전 안내. 무엇이 필요한지만 알려준다 */
  gate(shareToken: string): Promise<ShareGate> {
    return this.#request("GET", `/api/public/share/${encodeURIComponent(shareToken)}`);
  }

  enter(
    shareToken: string,
    body: { display_name?: string; email?: string; pincode?: string } = {},
  ): Promise<ShareEntry> {
    return this.#request("POST", `/api/public/share/${encodeURIComponent(shareToken)}/enter`, body);
  }

  /** 게스트가 보는 회의. 어느 회의인지는 서버가 안다 */
  meeting(): Promise<Meeting> {
    return this.#request("GET", "/api/public/guest/meeting");
  }

  leave(): Promise<void> {
    return this.#request("DELETE", "/api/public/guest/session");
  }

  async #request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = { accept: "application/json" };
    if (body !== undefined) headers["content-type"] = "application/json";
    if (this.#token) headers["x-guest-token"] = this.#token;

    const response = await fetch(`${this.#baseUrl}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });

    if (response.status === 204) return undefined as T;

    const text = await response.text();
    const payload = text ? (JSON.parse(text) as Record<string, unknown>) : {};

    if (!response.ok) {
      throw new GuestApiError(
        (payload["message"] as string) || "요청을 처리하지 못했습니다",
        response.status,
        (payload["code"] as string) || "error",
      );
    }

    return payload as T;
  }
}

export class GuestApiError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(message: string, status: number, code: string) {
    super(message);
    this.name = "GuestApiError";
    this.status = status;
    this.code = code;
  }
}
