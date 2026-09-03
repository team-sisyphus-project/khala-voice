import type { CurrentAccount, Friend, Meeting, Role } from "../api/types";

/**
 * View-scope resolution logic.
 *
 * **Source: sisyphus** — `VIEW_SCOPES` and `normalizeViewScope` from
 * `assets/shared/components/core-ui.js`, and the view-scope editor in
 * `assets/webapp/meeting-recorder.js`.
 *
 * Changes:
 * - `selected_members` → `selected_friends`, `project_members` → `all_friends`
 *   (this app has no projects; the sharing audience is friends)
 * - storage key `memberIds` → `accountIds`
 * - removed hard-coded pastel colors — with four themes, light-only colors
 *   are unreadable
 *
 * ## The server has the final say
 *
 * Everything here exists to draw the UI. Actual permissions are computed by
 * the server's `VR.Access.AccessLevel.resolve/3`, and every mutation API
 * validates again.
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
  /** A scope that only makes sense with friends */
  needsFriends: boolean;
}

export const VIEW_SCOPES: readonly ScopeOption[] = [
  {
    mode: "me_only",
    icon: "lock_person",
    label: "Only me",
    hint: "Only me, the reviewer, can see it",
    needsFriends: false,
  },
  {
    mode: "assignees_only",
    icon: "lock",
    label: "Participants only",
    hint: "Only the reviewer and contributors can see it",
    needsFriends: false,
  },
  {
    mode: "selected_friends",
    icon: "group_add",
    label: "Selected friends",
    hint: "Chosen friends can watch as viewers",
    needsFriends: true,
  },
  {
    mode: "all_friends",
    icon: "groups",
    label: "All my friends",
    hint: "Everyone on my friend list watches as a viewer",
    needsFriends: true,
  },
] as const;

const DEFAULT_MODE: ViewScopeMode = "assignees_only";

/** Same mapping as the server's `normalize_view_scope/1`. Accepts legacy values too. */
export function normalizeViewScope(raw: unknown): ViewScopeMode {
  if (typeof raw !== "string") return DEFAULT_MODE;

  switch (raw) {
    case "me_only":
    case "assignees_only":
    case "selected_friends":
    case "all_friends":
      return raw;
    // sisyphus values
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
 * Pulls the view scope out of `meeting.permissions`.
 *
 * Must not crash whatever shape arrives — this is a free-form map the server
 * fills, and old data may lack `view` entirely.
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
 * Builds the save payload.
 *
 * **The key is `accountIds` (camelCase).** The server's list query looks up
 * `permissions #> '{view,accountIds}'`, so sending snake_case opens the
 * detail view fine but **the meeting vanishes from lists.**
 *
 * **The `view` object always carries both keys.** The server's
 * `permissions_changeset` replaces the map wholesale, so a partial send is
 * a data wipe.
 */
export function buildPermissions(next: ViewPermission): {
  view: { mode: ViewScopeMode; accountIds: string[] };
} {
  return {
    view: {
      mode: next.mode,
      // Outside selected mode the list is meaningless. Keeping it means that
      // when the mode is switched back, recipients the user forgot about
      // come back to life.
      accountIds: next.mode === "selected_friends" ? next.accountIds : [],
    },
  };
}

/** Can this role change the view scope? The server re-checks with lv0 too. */
export function canManagePermissions(role: Role): boolean {
  return role === "reviewer";
}

/** One-line description for the header chip. */
export function describeScope(view: ViewPermission, friendCount: number): string {
  switch (view.mode) {
    case "me_only":
      return "Only me";
    case "assignees_only":
      return "Participants only";
    case "selected_friends":
      return view.accountIds.length > 0 ? `${view.accountIds.length} friends` : "No friends selected";
    case "all_friends":
      return `All my friends (${friendCount})`;
  }
}

/**
 * Is it "Only me" while contributors remain?
 *
 * The server's permission check tests **contributors before the view scope**
 * (the `cond` order in `access_level.ex`). So even after switching to
 * "Only me", contributors keep seeing it. The user believes it went private
 * when it did not, so the UI must say so.
 */
export function leakyPrivate(
  meeting: Pick<Meeting, "contributor_ids">,
  view: ViewPermission,
): boolean {
  return view.mode === "me_only" && (meeting.contributor_ids?.length ?? 0) > 0;
}

/**
 * Account id → person's name. `null` when not found.
 *
 * Stale ids left after unfriending land here. The UI **must not hide them** —
 * what cannot be seen cannot be removed, so it lingers forever.
 */
export function displayName(
  id: string,
  friends: Friend[],
  me: CurrentAccount | null,
): string | null {
  if (me && id === me.id) return me.name || me.email || "Me";

  const friend = friends.find((f) => f.id === id);
  return friend ? friend.name || friend.email : null;
}
