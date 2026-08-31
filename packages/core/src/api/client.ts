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

  /** 다시 시도해볼 만한 오류인가. 4xx 는 재시도해도 같은 결과다. */
  get retryable(): boolean {
    return this.status === 0 || this.status === 408 || this.status === 429 || this.status >= 500;
  }
}

export interface ApiClientOptions {
  baseUrl?: string;
  /** CSRF 토큰. Phoenix 가 meta 태그로 넣어준다 */
  csrfToken?: string;
}

/**
 * 타입 있는 API 클라이언트.
 *
 * 세션 쿠키로 인증한다 (`credentials: "same-origin"`).
 * 토큰을 JS 가 들고 있지 않으므로 XSS 로 세션이 새지 않는다.
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

  // ── 계정 ───────────────────────────────────────────────

  me(): Promise<CurrentAccount> {
    return this.#request("GET", "/api/me");
  }

  /** 기본 전사 언어. `null` 이면 자동(브라우저 언어)으로 되돌린다. */
  // ── 칼라 연동 ──────────────────────────────────────────

  khalaStatus(): Promise<KhalaStatus> {
    return this.#request("GET", "/api/khala");
  }

  khalaInboxes(): Promise<{ inboxes: KhalaInbox[] }> {
    return this.#request("GET", "/api/khala/inboxes");
  }

  khalaDisconnect(): Promise<void> {
    return this.#request("DELETE", "/api/khala");
  }

  /** 회의를 칼라 인박스로 보낸다. Reviewer 만 할 수 있다 — 서버가 다시 판정한다. */
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

  // ── MCP 읽기 토큰 ──────────────────────────────────────

  mcpTokens(): Promise<{ tokens: MCPToken[] }> {
    return this.#request("GET", "/api/mcp-tokens");
  }

  /** 평문 토큰은 **이 응답에만** 들어 있다. */
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

  /** UI 표시 언어를 바꾼다. 전사 언어와 별개다. */
  updateLocale(locale: string): Promise<CurrentAccount> {
    return this.#request("PATCH", "/api/me/locale", { locale });
  }

  /** 친구 목록. 화자를 사람에 연결할 때 쓴다. */
  friends(): Promise<{ friends: Friend[] }> {
    return this.#request("GET", "/api/friends");
  }

  // ── 회의 ───────────────────────────────────────────────

  /**
   * 회의 목록. `total` 은 필터에 걸린 **전체** 개수다 (이 페이지 개수가 아니다).
   *
   * `label_ids` 는 쉼표로 잇는다. 서버가 배열도 받지만 URL 쿼리로는 문자열이 자연스럽다.
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

  /** 이 회의에 붙일 수 있는 분류 — **회의 owner 의 것**이다 */
  meetingTaxonomy(id: string): Promise<{ topics: Topic[]; labels: Label[] }> {
    return this.#request("GET", `/api/meetings/${encodeURIComponent(id)}/taxonomy`);
  }

  /**
   * 공개 범위 · Reviewer · Contributor · 게스트 스위치. **Reviewer 만.**
   *
   * `permissions` 는 **통째로 교체된다.** 일부만 보내면 나머지가 지워진다.
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

  /** 내 요금 상태. 계정 id 를 보내지 않는다 — 서버가 세션에서 안다 */
  billing(limit?: number): Promise<BillingSummary> {
    const suffix = limit ? `?limit=${limit}` : "";
    return this.#request("GET", `/api/me/billing${suffix}`);
  }

  // ── 웹 푸시 ──────────────────────────────────────────────

  pushStatus(): Promise<{ enabled: boolean; public_key: string | null; subscriptions: number }> {
    return this.#request("GET", "/api/me/push");
  }

  /** 브라우저의 `PushSubscription.toJSON()` 을 그대로 보낸다 */
  subscribePush(subscription: unknown): Promise<void> {
    return this.#request("POST", "/api/me/push", subscription);
  }

  unsubscribePush(endpoint: string): Promise<void> {
    return this.#request("DELETE", "/api/me/push", { endpoint });
  }

  // ── 공유 링크 (Reviewer) ─────────────────────────────────

  listShareLinks(meetingId: string): Promise<{ share_links: SharedLink[] }> {
    return this.#request("GET", `/api/meetings/${encodeURIComponent(meetingId)}/share-links`);
  }

  /** 응답의 `url` 과 `pincode` 는 **이때 한 번만** 온다 */
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

  /** 주소를 잃어버렸을 때. 기존 URL 이 즉시 무효가 된다 */
  rotateShareLink(id: string): Promise<SharedLink> {
    return this.#request("POST", `/api/share-links/${encodeURIComponent(id)}/rotate`, {});
  }

  setShareLinkPincode(id: string, enabled: boolean): Promise<SharedLink> {
    return this.#request("POST", `/api/share-links/${encodeURIComponent(id)}/pincode`, { enabled });
  }

  /** 폐기. **이 링크로 들어와 있는 게스트도 즉시 끊긴다** */
  deleteShareLink(id: string): Promise<void> {
    return this.#request("DELETE", `/api/share-links/${encodeURIComponent(id)}`);
  }

  // ── 분류 ─────────────────────────────────────────────────

  listTopics(): Promise<{ topics: Topic[] }> {
    return this.#request("GET", "/api/topics");
  }

  createTopic(body: { name: string; color?: ColorKey }): Promise<Topic> {
    return this.#request("POST", "/api/topics", body);
  }

  updateTopic(id: string, body: { name?: string; color?: ColorKey }): Promise<Topic> {
    return this.#request("PATCH", `/api/topics/${encodeURIComponent(id)}`, body);
  }

  /** 지우면 쓰던 회의에서 떨어진다. 몇 개가 풀렸는지 돌려준다 */
  deleteTopic(id: string): Promise<{ status: string; detached_meetings: number }> {
    return this.#request("DELETE", `/api/topics/${encodeURIComponent(id)}`);
  }

  /** **전체 목록을 통째로** 보낸다. 일부만 보내면 서버가 거부한다 */
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

  // ── 녹음 세션 ──────────────────────────────────────────

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
   * 업로드 완료를 알린다.
   *
   * **주소를 보내지 않는다.** 저장 위치는 presign 단계에서 서버가 정했다 —
   * 클라이언트가 준 주소를 서버가 그대로 받아 내려받으면 SSRF 가 된다.
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

  /** 전사를 시작한다. 큐잉만 하고 즉시 돌아온다 — 완료는 폴링으로 확인한다. */
  transcribeSession(sessionId: string): Promise<RecordingSession> {
    return this.#request("POST", `/api/sessions/${encodeURIComponent(sessionId)}/transcribe`);
  }

  /**
   * 화자 매핑 또는 전사 본문을 갱신한다.
   *
   * 둘 다 같은 엔드포인트다 — 화자 칩 변경은 `speaker_map`,
   * 세그먼트 변경·텍스트 편집은 `transcript` 를 보낸다.
   */
  /** 요약을 다시 만든다. 큐잉만 하고 바로 돌아온다 — 완료는 폴링으로 확인한다 */
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

  // ── 내부 ───────────────────────────────────────────────

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
      // 네트워크 자체가 실패한 경우. status 0 으로 재시도 가능 표시.
      throw new ApiRequestError(0, "network_error", "네트워크에 연결할 수 없습니다");
    }

    if (response.status === 204) return undefined as T;

    const text = await response.text();
    const payload = text ? safeParse(text) : null;

    if (!response.ok) {
      const code = (payload as { code?: string })?.code ?? "unknown";
      const message = (payload as { message?: string })?.message ?? `요청 실패 (${response.status})`;
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
