import type {
  BillingSummary,
  ColorKey,
  CurrentAccount,
  GrantedRole,
  Friend,
  KhalaInbox,
  KhalaStatus,
  Label,
  MCPToken,
  MCPTokenIssued,
  Meeting,
  PresignResult,
  RecordingSession,
  SharedLink,
  SpeakerMapEntry,
  Topic,
  Transcript,
} from "./types";

export class ApiRequestError extends Error {
  readonly status: number;
  readonly code: string;
  readonly fieldErrors?: Record<string, string[]>;

  constructor(status: number, code: string, message: string, fieldErrors?: Record<string, string[]>) {
    super(message);
    this.name = "ApiRequestError";
    this.status = status;
    this.code = code;
    this.fieldErrors = fieldErrors;
  }

  /** Is this error worth retrying? A 4xx gives the same result on retry. */
  get retryable(): boolean {
    return this.status === 0 || this.status === 408 || this.status === 429 || this.status >= 500;
  }
}

export interface ApiClientOptions {
  baseUrl?: string;
  /** CSRF token. Phoenix injects it via a meta tag */
  csrfToken?: string;
}

/**
 * Typed API client.
 *
 * Authenticates with the session cookie (`credentials: "same-origin"`).
 * JS never holds a token, so XSS cannot leak the session.
 */
export class ApiClient {
  #baseUrl: string;
  #csrfToken: string | undefined;

  constructor(options: ApiClientOptions = {}) {
    this.#baseUrl = (options.baseUrl ?? "").replace(/\/$/, "");
    this.#csrfToken =
      options.csrfToken ??
      document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content;
  }

  // ── Account ────────────────────────────────────────────

  me(): Promise<CurrentAccount> {
    return this.#request("GET", "/api/me");
  }

  /** Default transcription language. `null` reverts to auto (browser language). */
  /**
   * Logs out this device only. Other devices are left alone.
   *
   * On success the session is gone, so **the caller must redirect to the
   * sign-in screen.**
   */
  logout(): Promise<void> {
    return this.#request("DELETE", "/api/me/session");
  }

  // ── Khala integration ──────────────────────────────────

  khalaStatus(): Promise<KhalaStatus> {
    return this.#request("GET", "/api/khala");
  }

  khalaInboxes(): Promise<{ inboxes: KhalaInbox[] }> {
    return this.#request("GET", "/api/khala/inboxes");
  }

  khalaDisconnect(): Promise<void> {
    return this.#request("DELETE", "/api/khala");
  }

  /** Sends a meeting to a Khala inbox. Reviewer only — the server re-checks. */
  sendMeetingToKhala(
    meetingId: string,
    body: { recipient_inbox_code: string; attach_transcript?: boolean },
  ): Promise<{ sent: boolean }> {
    return this.#request(
      "POST",
      `/api/meetings/${encodeURIComponent(meetingId)}/khala`,
      body,
    );
  }

  // ── MCP read tokens ────────────────────────────────────

  mcpTokens(): Promise<{ tokens: MCPToken[] }> {
    return this.#request("GET", "/api/mcp-tokens");
  }

  /** The plaintext token appears **only in this response**. */
  createMCPToken(body: { name: string }): Promise<MCPTokenIssued> {
    return this.#request("POST", "/api/mcp-tokens", body);
  }

  revokeMCPToken(id: string): Promise<void> {
    return this.#request("DELETE", `/api/mcp-tokens/${encodeURIComponent(id)}`);
  }

  updateTranscribeLanguage(language: string | null): Promise<CurrentAccount> {
    return this.#request("PATCH", "/api/me/transcribe-language", {
      transcribe_language: language,
    });
  }

  updateTheme(theme: string): Promise<CurrentAccount> {
    return this.#request("PATCH", "/api/me/theme", { theme });
  }

  /** Changes the UI display language. Separate from the transcription language. */
  updateLocale(locale: string): Promise<CurrentAccount> {
    return this.#request("PATCH", "/api/me/locale", { locale });
  }

  /** Friend list. Used when linking speakers to people. */
  friends(): Promise<{ friends: Friend[] }> {
    return this.#request("GET", "/api/friends");
  }

  // ── Meetings ───────────────────────────────────────────

  /**
   * Meeting list. `total` is the **overall** count matching the filter
   * (not this page's count).
   *
   * `label_ids` is comma-joined. The server accepts arrays too, but a string
   * is more natural in a URL query.
   */
  listMeetings(
    params: Record<string, string | undefined> = {},
  ): Promise<{ meetings: Meeting[]; total: number }> {
    const query = new URLSearchParams(
      Object.entries(params).filter((entry): entry is [string, string] => entry[1] != null),
    );
    const suffix = query.toString() ? `?${query}` : "";
    return this.#request("GET", `/api/meetings${suffix}`);
  }

  /** Taxonomy attachable to this meeting — it belongs to the **meeting owner** */
  meetingTaxonomy(id: string): Promise<{ topics: Topic[]; labels: Label[] }> {
    return this.#request("GET", `/api/meetings/${encodeURIComponent(id)}/taxonomy`);
  }

  /**
   * View scope · reviewer · contributors · guest switch. **Reviewer only.**
   *
   * `permissions` is **replaced wholesale.** Sending part of it wipes the rest.
   */
  updateMeetingPermissions(
    id: string,
    body: {
      permissions?: { view: { mode: string; accountIds: string[] } };
      reviewer_id?: string;
      contributor_ids?: string[];
      guest_link_enabled?: boolean;
    },
  ): Promise<Meeting> {
    return this.#request("PATCH", `/api/meetings/${encodeURIComponent(id)}/permissions`, body);
  }

  /** My billing status. No account id is sent — the server knows it from the session */
  billing(limit?: number): Promise<BillingSummary> {
    const suffix = limit ? `?limit=${limit}` : "";
    return this.#request("GET", `/api/me/billing${suffix}`);
  }

  // ── Web push ─────────────────────────────────────────────

  pushStatus(): Promise<{ enabled: boolean; public_key: string | null; subscriptions: number }> {
    return this.#request("GET", "/api/me/push");
  }

  /** Sends the browser's `PushSubscription.toJSON()` as-is */
  subscribePush(subscription: unknown): Promise<void> {
    return this.#request("POST", "/api/me/push", subscription);
  }

  unsubscribePush(endpoint: string): Promise<void> {
    return this.#request("DELETE", "/api/me/push", { endpoint });
  }

  // ── Share links (Reviewer) ───────────────────────────────

  listShareLinks(meetingId: string): Promise<{ share_links: SharedLink[] }> {
    return this.#request("GET", `/api/meetings/${encodeURIComponent(meetingId)}/share-links`);
  }

  /** The response's `url` and `pincode` arrive **only this once** */
  createShareLink(
    meetingId: string,
    body: {
      granted_role: GrantedRole;
      max_uses?: number | null;
      expires_at?: string | null;
      require_name?: boolean;
      require_email?: boolean;
      with_pincode?: boolean;
    },
  ): Promise<SharedLink> {
    return this.#request("POST", `/api/meetings/${encodeURIComponent(meetingId)}/share-links`, body);
  }

  updateShareLink(id: string, body: Record<string, unknown>): Promise<SharedLink> {
    return this.#request("PATCH", `/api/share-links/${encodeURIComponent(id)}`, body);
  }

  /** For a lost address. The old URL becomes invalid immediately */
  rotateShareLink(id: string): Promise<SharedLink> {
    return this.#request("POST", `/api/share-links/${encodeURIComponent(id)}/rotate`, {});
  }

  setShareLinkPincode(id: string, enabled: boolean): Promise<SharedLink> {
    return this.#request("POST", `/api/share-links/${encodeURIComponent(id)}/pincode`, { enabled });
  }

  /** Revoke. **Guests currently in via this link are cut off immediately** */
  deleteShareLink(id: string): Promise<void> {
    return this.#request("DELETE", `/api/share-links/${encodeURIComponent(id)}`);
  }

  // ── Taxonomy ─────────────────────────────────────────────

  listTopics(): Promise<{ topics: Topic[] }> {
    return this.#request("GET", "/api/topics");
  }

  createTopic(body: { name: string; color?: ColorKey }): Promise<Topic> {
    return this.#request("POST", "/api/topics", body);
  }

  updateTopic(id: string, body: { name?: string; color?: ColorKey }): Promise<Topic> {
    return this.#request("PATCH", `/api/topics/${encodeURIComponent(id)}`, body);
  }

  /** Deleting detaches it from meetings that used it. Returns how many were detached */
  deleteTopic(id: string): Promise<{ status: string; detached_meetings: number }> {
    return this.#request("DELETE", `/api/topics/${encodeURIComponent(id)}`);
  }

  /** Sends **the entire list wholesale.** The server rejects partial lists */
  reorderTopics(ids: string[]): Promise<{ topics: Topic[] }> {
    return this.#request("PATCH", "/api/topics/reorder", { ids });
  }

  listLabels(): Promise<{ labels: Label[] }> {
    return this.#request("GET", "/api/labels");
  }

  createLabel(body: { name: string; color?: ColorKey }): Promise<Label> {
    return this.#request("POST", "/api/labels", body);
  }

  updateLabel(id: string, body: { name?: string; color?: ColorKey }): Promise<Label> {
    return this.#request("PATCH", `/api/labels/${encodeURIComponent(id)}`, body);
  }

  deleteLabel(id: string): Promise<{ status: string; detached_meetings: number }> {
    return this.#request("DELETE", `/api/labels/${encodeURIComponent(id)}`);
  }

  getMeeting(id: string): Promise<Meeting> {
    return this.#request("GET", `/api/meetings/${encodeURIComponent(id)}`);
  }

  createMeeting(body: { title?: string; description?: string } = {}): Promise<Meeting> {
    return this.#request("POST", "/api/meetings", body);
  }

  updateMeeting(id: string, body: Record<string, unknown>): Promise<Meeting> {
    return this.#request("PATCH", `/api/meetings/${encodeURIComponent(id)}`, body);
  }

  setMeetingStatus(id: string, status: string): Promise<Meeting> {
    return this.#request("PATCH", `/api/meetings/${encodeURIComponent(id)}/status`, { status });
  }

  deleteMeeting(id: string): Promise<void> {
    return this.#request("DELETE", `/api/meetings/${encodeURIComponent(id)}`);
  }

  // ── Recording sessions ─────────────────────────────────

  createSession(
    meetingId: string,
    body: { started_at_unix?: number; metadata?: Record<string, unknown> } = {},
  ): Promise<RecordingSession> {
    return this.#request("POST", `/api/meetings/${encodeURIComponent(meetingId)}/sessions`, body);
  }

  presignUpload(params: { sessionId: string; contentType: string }): Promise<PresignResult> {
    return this.#request("POST", "/api/uploads/presign", {
      session_id: params.sessionId,
      content_type: params.contentType,
    });
  }

  /**
   * Reports upload completion.
   *
   * **No URL is sent.** The server chose the storage location at presign
   * time — if the server downloaded from a client-supplied URL as-is,
   * that would be SSRF.
   */
  registerUpload(
    sessionId: string,
    body: {
      duration_seconds: number;
      file_size_bytes: number;
      mime_type: string;
    },
  ): Promise<RecordingSession> {
    return this.#request("POST", `/api/sessions/${encodeURIComponent(sessionId)}/upload`, body);
  }

  /** Starts transcription. Only enqueues and returns immediately — poll for completion. */
  transcribeSession(sessionId: string): Promise<RecordingSession> {
    return this.#request("POST", `/api/sessions/${encodeURIComponent(sessionId)}/transcribe`);
  }

  /**
   * Updates the speaker mapping or the transcript body.
   *
   * Both use the same endpoint — speaker chip changes send `speaker_map`,
   * segment changes and text edits send `transcript`.
   */
  /** Regenerates the summary. Only enqueues and returns right away — poll for completion */
  summarize(meetingId: string): Promise<{ status: string; meeting_id: string }> {
    return this.#request("POST", `/api/meetings/${encodeURIComponent(meetingId)}/summarize`, {});
  }

  updateSpeakers(
    sessionId: string,
    patch: { speaker_map?: Record<string, SpeakerMapEntry>; transcript?: Transcript },
  ): Promise<RecordingSession> {
    return this.#request("PATCH", `/api/sessions/${encodeURIComponent(sessionId)}/speakers`, patch);
  }

  deleteSession(sessionId: string): Promise<void> {
    return this.#request("DELETE", `/api/sessions/${encodeURIComponent(sessionId)}`);
  }

  // ── Internal ───────────────────────────────────────────

  async #request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = { Accept: "application/json" };

    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (this.#csrfToken) headers["x-csrf-token"] = this.#csrfToken;

    let response: Response;

    try {
      response = await fetch(`${this.#baseUrl}${path}`, {
        method,
        headers,
        credentials: "same-origin",
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch {
      // The network itself failed. status 0 marks it retryable.
      throw new ApiRequestError(0, "network_error", "Could not reach the network");
    }

    if (response.status === 204) return undefined as T;

    const text = await response.text();
    const payload = text ? safeParse(text) : null;

    if (!response.ok) {
      const code = (payload as { code?: string })?.code ?? "unknown";
      const message = (payload as { message?: string })?.message ?? `Request failed (${response.status})`;
      const fieldErrors = (payload as { errors?: Record<string, string[]> })?.errors;
      throw new ApiRequestError(response.status, code, message, fieldErrors);
    }

    return payload as T;
  }
}

function safeParse(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
