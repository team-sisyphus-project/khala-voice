import type { CurrentAccount, Friend, Meeting, Role } from "../api/types";

/**
 * 공개 범위(View Scope) 판정 로직.
 *
 * **출처: sisyphus** `assets/shared/components/core-ui.js` 의 `VIEW_SCOPES` 와
 * `normalizeViewScope`, `assets/webapp/meeting-recorder.js` 의 공개범위 편집부.
 *
 * 바꾼 것:
 * - `selected_members` → `selected_friends`, `project_members` → `all_friends`
 *   (이 앱에는 프로젝트가 없다. 공개 대상은 친구다)
 * - 저장 키 `memberIds` → `accountIds`
 * - 파스텔 색 하드코딩 제거 — 테마가 넷이라 라이트 전용 색이 안 읽힌다
 *
 * ## 서버가 최종 판정한다
 *
 * 여기 있는 것은 화면을 그리기 위한 것이다. 실제 권한은 서버의
 * `VR.Access.AccessLevel.resolve/3` 가 계산하고, 모든 변경 API 가 다시 검증한다.
 */

export type ViewScopeMode = "me_only" | "assignees_only" | "selected_friends" | "all_friends";

export interface ViewPermission {
  mode: ViewScopeMode;
  accountIds: string[];
}

export interface ScopeOption {
  mode: ViewScopeMode;
  icon: string;
  label: string;
  hint: string;
  /** 친구가 있어야 의미가 있는 범위 */
  needsFriends: boolean;
}

export const VIEW_SCOPES: readonly ScopeOption[] = [
  {
    mode: "me_only",
    icon: "lock_person",
    label: "나만",
    hint: "Reviewer 인 나만 볼 수 있습니다",
    needsFriends: false,
  },
  {
    mode: "assignees_only",
    icon: "lock",
    label: "관계자만",
    hint: "Reviewer 와 Contributor 만 볼 수 있습니다",
    needsFriends: false,
  },
  {
    mode: "selected_friends",
    icon: "group_add",
    label: "지정한 친구",
    hint: "고른 친구가 Viewer 로 볼 수 있습니다",
    needsFriends: true,
  },
  {
    mode: "all_friends",
    icon: "groups",
    label: "내 친구 전체",
    hint: "내 친구 목록에 있는 사람 모두가 Viewer 로 봅니다",
    needsFriends: true,
  },
] as const;

const DEFAULT_MODE: ViewScopeMode = "assignees_only";

/** 서버의 `normalize_view_scope/1` 과 같은 매핑. 레거시 값도 받는다. */
export function normalizeViewScope(raw: unknown): ViewScopeMode {
  if (typeof raw !== "string") return DEFAULT_MODE;

  switch (raw) {
    case "me_only":
    case "assignees_only":
    case "selected_friends":
    case "all_friends":
      return raw;
    // sisyphus 값
    case "selected_members":
      return "selected_friends";
    case "project_members":
    case "all_users":
      return "all_friends";
    case "private":
      return "me_only";
    default:
      return DEFAULT_MODE;
  }
}

/**
 * `meeting.permissions` 에서 공개 범위를 꺼낸다.
 *
 * 어떤 모양이 와도 터지지 않아야 한다 — 이 값은 서버가 채우는 자유 형식 맵이고,
 * 옛 데이터에는 `view` 자체가 없을 수 있다.
 */
export function readViewPermission(permissions: Record<string, unknown> | undefined | null): ViewPermission {
  const view = permissions?.["view"];

  if (!view || typeof view !== "object") {
    return { mode: DEFAULT_MODE, accountIds: [] };
  }

  const raw = view as Record<string, unknown>;
  const ids = raw["accountIds"] ?? raw["account_ids"];

  return {
    mode: normalizeViewScope(raw["mode"]),
    accountIds: Array.isArray(ids) ? ids.filter((id): id is string => typeof id === "string") : [],
  };
}

/**
 * 저장 페이로드를 만든다.
 *
 * **키는 `accountIds`(camelCase) 다.** 서버의 목록 쿼리가
 * `permissions #> '{view,accountIds}'` 로 찾으므로 snake_case 로 보내면
 * 상세는 열리는데 **목록에서 사라진다.**
 *
 * **`view` 객체는 항상 두 키를 다 담는다.** 서버의 `permissions_changeset` 이
 * 맵을 통째로 교체하므로 부분 전송이 곧 데이터 삭제다.
 */
export function buildPermissions(next: ViewPermission): {
  view: { mode: ViewScopeMode; accountIds: string[] };
} {
  return {
    view: {
      mode: next.mode,
      // 지정 모드가 아니면 목록은 의미가 없다. 남겨두면 모드를 되돌렸을 때
      // 사용자가 기억하지 못하는 대상이 되살아난다.
      accountIds: next.mode === "selected_friends" ? next.accountIds : [],
    },
  };
}

/** 공개 범위를 바꿀 수 있는 역할인가. 서버도 lv0 으로 다시 판정한다. */
export function canManagePermissions(role: Role): boolean {
  return role === "reviewer";
}

/** 헤더 칩에 쓰는 한 줄 설명. */
export function describeScope(view: ViewPermission, friendCount: number): string {
  switch (view.mode) {
    case "me_only":
      return "나만";
    case "assignees_only":
      return "관계자만";
    case "selected_friends":
      return view.accountIds.length > 0 ? `친구 ${view.accountIds.length}명` : "지정한 친구 없음";
    case "all_friends":
      return `내 친구 전체 (${friendCount}명)`;
  }
}

/**
 * "나만" 인데 Contributor 가 남아 있는가.
 *
 * 서버의 권한 계산은 **Contributor 검사를 공개 범위보다 먼저** 한다
 * (`access_level.ex` 의 `cond` 순서). 그래서 "나만" 으로 바꿔도 Contributor 는
 * 계속 본다. 사용자는 비공개로 만들었다고 믿는데 아니므로 화면에서 알려줘야 한다.
 */
export function leakyPrivate(
  meeting: Pick<Meeting, "contributor_ids">,
  view: ViewPermission,
): boolean {
  return view.mode === "me_only" && (meeting.contributor_ids?.length ?? 0) > 0;
}

/**
 * 계정 id 를 사람 이름으로. 못 찾으면 `null`.
 *
 * 친구를 끊은 뒤 남은 옛 id 가 여기 걸린다. 화면에서 **숨기면 안 된다** —
 * 안 보이면 지울 수도 없어서 영원히 남는다.
 */
export function displayName(
  id: string,
  friends: Friend[],
  me: CurrentAccount | null,
): string | null {
  if (me && id === me.id) return me.name || me.email || "나";

  const friend = friends.find((f) => f.id === id);
  return friend ? friend.name || friend.email : null;
}
