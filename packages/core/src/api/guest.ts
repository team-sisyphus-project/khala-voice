import type { Meeting, ShareEntry, ShareGate } from "./types";

/**
 * Guest-only API client.
 *
 * ## Why a separate client
 *
 * Guest credentials travel in the `X-Guest-Token` header. We avoid cookies
 * because (a) the `:api` pipeline has no CSRF defense and (b) cookies are
 * domain-wide, which conflicts with the "one meeting only" constraint.
 *
 * ## No meeting id is sent
 *
 * The meeting a guest sees is **decided by the server-side guest session.**
 * The client has no way to specify a meeting, so pointing at another meeting
 * is impossible by construction.
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

  /** Pre-entry gate info. Only says what is required */
  gate(shareToken: string): Promise<ShareGate> {
    return this.#request("GET", `/api/public/share/${encodeURIComponent(shareToken)}`);
  }

  enter(
    shareToken: string,
    body: { display_name?: string; email?: string; pincode?: string } = {},
  ): Promise<ShareEntry> {
    return this.#request("POST", `/api/public/share/${encodeURIComponent(shareToken)}/enter`, body);
  }

  /** The meeting the guest sees. The server knows which one */
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
        (payload["message"] as string) || "The request could not be processed",
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
