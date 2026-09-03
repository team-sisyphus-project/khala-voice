/** Response types of the server API. Kept in sync with `VRWeb.API.JSONView`. */

export type Role = "reviewer" | "contributor" | "viewer" | "none";
export type MeetingStatus = "active" | "completed" | "archived";
export type SessionStatus =
  | "recording"
  | "uploaded"
  | "splitting"
  | "transcribing"
  | "completed"
  | "failed";

export interface TranscriptSegment {
  speaker: string;
  text: string;
  start_ms: number;
  end_ms: number;
  confidence?: number;
}

export interface Transcript {
  segments: TranscriptSegment[];
  original_segments?: TranscriptSegment[];
}

export interface SpeakerMapEntry {
  name: string;
  account_id: string | null;
}

export interface RecordingSession {
  id: string;
  meeting_id: string;
  session_index: number;
  status: SessionStatus;
  started_at_unix: number;
  duration_seconds: number | null;
  /** The server never sends this to viewers at all */
  /**
   * Path for fetching the audio. The server redirects to a signed URL.
   *
   * Not sent to viewers. We never hand out the raw URL directly because the
   * storage key is deterministic — an unsigned address would be a permanent
   * public link.
   */
  audio_href?: string;
  transcript: Transcript | null;
  speaker_map: Record<string, SpeakerMapEntry>;
  credits_charged: number;
  file_size_bytes: number | null;
  mime_type: string | null;
  metadata: Record<string, unknown>;
  error_message: string | null;
  inserted_at: string;
}

export interface SummarySource {
  session_id: string;
  speaker: string;
  time_label: string;
  quote: string;
  /** Attached by the server after checking against the actual transcript. Used to jump playback right there */
  start_ms: number;
}

export interface SummaryData {
  one_liner: string;
  /** `source` is attached only when verified against the transcript. null if not found — the item stays */
  decisions: { text: string; source: SummarySource | null }[];
  action_items: { who: string; what: string; due: string; source: SummarySource | null }[];
  facts: string[];
  open_questions: string[];
  next_steps: string[];
  key_topics: string[];
  language?: string;
  provider?: string;
  model?: string;
  generated_at?: string;
  included_session_ids?: string[];
  skipped_session_ids?: string[];
  /**
   * How many chunks the summary was split into. 1 means it fit in one pass.
   *
   * Long meetings are summarized **in chunks, never truncated** — truncation
   * silently drops the tail.
   */
  chunk_count?: number;
}

export type ColorKey =
  | "red" | "orange" | "yellow" | "green" | "teal"
  | "blue" | "indigo" | "violet" | "purple" | "gray";

/** Topic — a meeting gets **exactly one** */
export interface Topic {
  id: string;
  name: string;
  color: ColorKey;
  sort_order: number;
  /** Soft-deleted. Hidden from lists, but meetings still referencing it need the name */
  deleted: boolean;
  meeting_count?: number;
}

/** Label — a meeting can have **several** */
export interface Label {
  id: string;
  name: string;
  color: ColorKey;
  deleted: boolean;
  meeting_count?: number;
}

export type GrantedRole = "viewer" | "contributor";

/**
 * Shared link.
 *
 * **The plaintext token and PIN ride only on issue / rotate / PIN-enable
 * responses.** The server DB holds only hashes, so a lost one can only be
 * reissued.
 */
export interface SharedLink {
  id: string;
  granted_role: GrantedRole;
  /** First 12 chars. Only for telling links apart in lists */
  token_prefix: string;
  max_uses: number | null;
  use_count: number;
  expires_at: string | null;
  is_active: boolean;
  require_name: boolean;
  require_email: boolean;
  has_pincode: boolean;
  pin_locked_until: string | null;
  last_used_at: string | null;
  inserted_at: string;
  /** Only right after issue/rotate */
  url?: string;
  /** Only right after issue/PIN enable */
  pincode?: string | null;
}

/** What a guest receives before entering. **No meeting content.** */
export interface ShareGate {
  granted_role: GrantedRole;
  require_name: boolean;
  require_email: boolean;
  require_pincode: boolean;
  already_signed_in: boolean;
}

export interface ShareEntry {
  mode: "guest" | "account";
  guest_token: string | null;
  granted_role?: GrantedRole;
  expires_at?: string;
  /** When entered with a signed-in account. Sent to the meeting without a guest session */
  redirect?: string;
}

export interface BillingPlan {
  key: string;
  display_name: string;
  included_credits: number | null;
  interval: string | null;
}

export interface CreditLot {
  id: string;
  source: string;
  amount: number;
  remaining: number;
  expires_at: string | null;
  inserted_at: string;
}

export interface LedgerEntry {
  id: string;
  /** + grant / - usage */
  delta: number;
  source: string;
  reason: string | null;
  charge_domain: string | null;
  usage_cost_usd: string | null;
  /** Evidence for "why this much was charged". Holds token counts, rates, duration */
  pricing_snapshot: Record<string, unknown> | null;
  inserted_at: string;
}

export interface BillingSummary {
  /** **Can go negative** via overdraft */
  balance: number;
  plan: BillingPlan | null;
  subscription: {
    /** `active` · `past_due` · `canceled` … the server's `state` */
    status: string;
    current_period_start: string;
    current_period_end: string;
  } | null;
  lots: CreditLot[];
  entries: LedgerEntry[];
}

export interface Meeting {
  id: string;
  title: string | null;
  description: string | null;
  status: MeetingStatus;
  started_at: string | null;
  owner_id: string;
  reviewer_id: string | null;
  contributor_ids: string[];
  topic_id: string | null;
  label_ids: string[];
  /** The server expands name and color. Present only in list/detail responses */
  topic?: Topic | null;
  labels?: Label[];
  total_duration_seconds: number;
  total_credits_charged: number;
  summary: string | null;
  summary_data: SummaryData | null;
  /** Last summary failure. Cleared on success — existing summary_data stays */
  last_summary_error: { reason?: string; at?: string } | null;
  guest_link_enabled: boolean;
  archived_at: string | null;
  inserted_at: string;
  updated_at: string;
  /** My role as computed by the server. Used only to draw the UI — the server already decided */
  role: Role;
  view_level: "lv0" | "lv1" | "lv2" | "lv3";
  /** Sent to the reviewer only */
  permissions?: Record<string, unknown>;
  recording_sessions?: RecordingSession[];
}

export interface PresignResult {
  upload_url: string;
  download_url: string;
  key: string;
  expires_in: number;
  content_type: string;
}

export interface ApiError {
  status: "error";
  code: string;
  message: string;
  errors?: Record<string, string[]>;
}

export interface CurrentAccount {
  id: string;
  email: string;
  name: string | null;
  /** App UI language (ko · en · ja …). **Distinct from the transcription language.** */
  locale: string;
  theme: string;
  /**
   * Default transcription language (BCP-47, e.g. `ko-KR` · `cmn-Hans-CN`).
   *
   * `null` means **auto** — follow the browser language. Using the app in one
   * language while recording meetings in another is common, so this is not
   * tied to `locale`.
   */
  transcribe_language: string | null;
  confirmed: boolean;
  /**
   * Used **only to decide whether to show** the admin link.
   * The server re-checks access and returns 404 without permission.
   * Tampering with this value cannot get you into the admin area.
   */
  is_admin: boolean;
}

export interface Friend {
  id: string;
  name: string | null;
  email: string;
}


// ── Khala integration · MCP ──────────────────────────────
//
// Two things pointing in opposite directions (`docs/15-mcp-khala.md`):
//
//   KhalaStatus  us → Khala   we send to someone else's inbox
//   MCPToken     them → us    outsiders read our archive

export interface KhalaInbox {
  code: string | null;
  name: string | null;
  tagline?: string | null;
}

export interface KhalaStatus {
  /** Has the server enabled the integration? When off, it vanishes from the UI entirely */
  enabled: boolean;
  connected: boolean;
  /** **Our** inbox created on Khala — the sending side */
  inbox: KhalaInbox | null;
}

export interface MCPToken {
  id: string;
  name: string;
  /** Prefix only. The rest cannot be recovered */
  token_prefix: string;
  last_used_at: string | null;
  expires_at: string | null;
  inserted_at: string;
}

/** Only the issue response carries `token`. **This is the only time it is visible.** */
export interface MCPTokenIssued extends MCPToken {
  token: string;
}
