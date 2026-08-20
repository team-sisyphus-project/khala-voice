/** 서버 API 의 응답 타입. `VRWeb.API.JSONView` 와 맞춘다. */

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
  /** Viewer 에게는 서버가 아예 내려주지 않는다 */
  /**
   * 오디오를 받는 경로. 서버가 서명된 URL 로 리다이렉트한다.
   *
   * Viewer 에게는 내려오지 않는다. 원본 URL 을 직접 주지 않는 이유는
   * 저장 키가 결정적이라 서명 없는 주소는 곧 영구 공개 링크이기 때문이다.
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
  /** 서버가 실제 전사와 대조해 붙인다. 이 값으로 바로 그 지점을 재생한다 */
  start_ms: number;
}

export interface SummaryData {
  one_liner: string;
  /** `source` 는 전사와 대조해 확인된 것만 붙는다. 못 찾으면 null — 항목은 남는다 */
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
   * 몇 덩어리로 나눠 요약했는가. 1 이면 한 번에 들어갔다.
   *
   * 긴 회의는 **자르지 않고 나눠서** 요약한다 — 자르면 뒷부분이 조용히 사라진다.
   */
  chunk_count?: number;
}

export type ColorKey =
  | "red" | "orange" | "yellow" | "green" | "teal"
  | "blue" | "indigo" | "violet" | "purple" | "gray";

/** 토픽 — 회의 하나에 **하나만** 붙는다 */
export interface Topic {
  id: string;
  name: string;
  color: ColorKey;
  sort_order: number;
  /** 소프트 삭제됨. 목록에는 안 나오지만 아직 참조가 남은 회의에서는 이름이 필요하다 */
  deleted: boolean;
  meeting_count?: number;
}

/** 라벨 — 회의 하나에 **여러 개** 붙는다 */
export interface Label {
  id: string;
  name: string;
  color: ColorKey;
  deleted: boolean;
  meeting_count?: number;
}

export type GrantedRole = "viewer" | "contributor";

/**
 * 공유 링크.
 *
 * **평문 토큰과 PIN 은 발급 · 재발급 · PIN 켜기 응답에만 실린다.**
 * 서버 DB 에도 해시만 있어서 잃어버리면 재발급뿐이다.
 */
export interface SharedLink {
  id: string;
  granted_role: GrantedRole;
  /** 앞 12자. 목록에서 어느 링크인지 알아보기만 한다 */
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
  /** 발급·재발급 직후에만 */
  url?: string;
  /** 발급·PIN 켜기 직후에만 */
  pincode?: string | null;
}

/** 게스트가 입장하기 전에 받는 안내. **회의 내용은 없다.** */
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
  /** 로그인 계정으로 들어왔을 때. 게스트 세션 없이 회의로 보낸다 */
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
  /** +지급 / -사용 */
  delta: number;
  source: string;
  reason: string | null;
  charge_domain: string | null;
  usage_cost_usd: string | null;
  /** "왜 이만큼 나갔나" 의 근거. 토큰 수·단가·길이가 들어 있다 */
  pricing_snapshot: Record<string, unknown> | null;
  inserted_at: string;
}

export interface BillingSummary {
  /** 오버드래프트로 **음수가 될 수 있다** */
  balance: number;
  plan: BillingPlan | null;
  subscription: {
    /** `active` · `past_due` · `canceled` … 서버의 `state` */
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
  /** 서버가 이름·색까지 풀어서 준다. 목록·상세 응답에만 들어 있다 */
  topic?: Topic | null;
  labels?: Label[];
  total_duration_seconds: number;
  total_credits_charged: number;
  summary: string | null;
  summary_data: SummaryData | null;
  /** 마지막 요약 실패. 성공하면 지워진다 — 기존 summary_data 는 남는다 */
  last_summary_error: { reason?: string; at?: string } | null;
  guest_link_enabled: boolean;
  archived_at: string | null;
  inserted_at: string;
  updated_at: string;
  /** 서버가 계산한 내 권한. UI 를 그릴 때만 쓴다 — 판정은 서버가 이미 끝냈다 */
  role: Role;
  view_level: "lv0" | "lv1" | "lv2" | "lv3";
  /** Reviewer 에게만 내려온다 */
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
  /** 앱 UI 의 언어 (ko · en · ja …). **전사 언어와 다른 값이다.** */
  locale: string;
  theme: string;
  /**
   * 기본 전사 언어 (BCP-47, 예: `ko-KR` · `cmn-Hans-CN`).
   *
   * `null` 은 **자동** — 브라우저 언어를 따라간다. 한국어로 앱을 쓰면서
   * 영어 회의를 녹음하는 것이 흔해서 `locale` 과 묶지 않는다.
   */
  transcribe_language: string | null;
  confirmed: boolean;
  /**
   * 어드민 링크를 **보여줄지 말지에만** 쓴다.
   * 접근 판정은 서버가 다시 하고, 권한이 없으면 404 를 준다.
   * 이 값을 조작해도 어드민에 들어갈 수 없다.
   */
  is_admin: boolean;
}

export interface Friend {
  id: string;
  name: string | null;
  email: string;
}
