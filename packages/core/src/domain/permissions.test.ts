import { deepEqual, equal } from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildPermissions,
  canManagePermissions,
  describeScope,
  displayName,
  leakyPrivate,
  normalizeViewScope,
  readViewPermission,
  VIEW_SCOPES,
} from "./permissions.ts";
import type { CurrentAccount, Friend } from "../api/types.ts";

describe("normalizeViewScope", () => {
  it("valid values pass through", () => {
    for (const scope of VIEW_SCOPES) {
      equal(normalizeViewScope(scope.mode), scope.mode);
    }
  });

  it("maps sisyphus values to this app's values", () => {
    equal(normalizeViewScope("selected_members"), "selected_friends");
    equal(normalizeViewScope("project_members"), "all_friends");
    equal(normalizeViewScope("all_users"), "all_friends");
    equal(normalizeViewScope("private"), "me_only");
  });

  it("narrows unknown values to the default", () => {
    // Erring toward the wider scope would let one piece of old data expose a meeting
    equal(normalizeViewScope("whatever"), "assignees_only");
    equal(normalizeViewScope(null), "assignees_only");
    equal(normalizeViewScope(42), "assignees_only");
  });
});

describe("readViewPermission", () => {
  it("does not crash on any shape", () => {
    deepEqual(readViewPermission(undefined), { mode: "assignees_only", accountIds: [] });
    deepEqual(readViewPermission(null), { mode: "assignees_only", accountIds: [] });
    deepEqual(readViewPermission({}), { mode: "assignees_only", accountIds: [] });
    deepEqual(readViewPermission({ view: {} }), { mode: "assignees_only", accountIds: [] });
    deepEqual(readViewPermission({ view: "text" }), { mode: "assignees_only", accountIds: [] });
  });

  it("reads both camelCase and snake_case", () => {
    // The server's AccessLevel reads both too. Saving uses camelCase only.
    deepEqual(readViewPermission({ view: { mode: "selected_friends", accountIds: ["a"] } }), {
      mode: "selected_friends",
      accountIds: ["a"],
    });

    deepEqual(readViewPermission({ view: { mode: "selected_friends", account_ids: ["a"] } }), {
      mode: "selected_friends",
      accountIds: ["a"],
    });
  });

  it("filters out values that are not account ids", () => {
    const result = readViewPermission({ view: { mode: "selected_friends", accountIds: ["a", 1, null] } });
    deepEqual(result.accountIds, ["a"]);
  });
});

describe("buildPermissions", () => {
  it("always carries both keys", () => {
    // permissions_changeset replaces the map wholesale. A partial send is a data wipe.
    const built = buildPermissions({ mode: "me_only", accountIds: [] });

    deepEqual(Object.keys(built.view).sort(), ["accountIds", "mode"]);
  });

  it("empties the recipient list outside selected mode", () => {
    for (const mode of ["me_only", "assignees_only", "all_friends"] as const) {
      deepEqual(buildPermissions({ mode, accountIds: ["a", "b"] }).view.accountIds, []);
    }
  });

  it("keeps the list in selected mode", () => {
    deepEqual(
      buildPermissions({ mode: "selected_friends", accountIds: ["a", "b"] }).view.accountIds,
      ["a", "b"],
    );
  });

  it("keys are camelCase", () => {
    // snake_case opens the detail view but misses the list query, so the meeting vanishes
    const json = JSON.stringify(buildPermissions({ mode: "selected_friends", accountIds: ["a"] }));

    ok(json.includes("accountIds"));
    ok(!json.includes("account_ids"));
  });
});

function ok(value: unknown) {
  equal(Boolean(value), true);
}

describe("leakyPrivate", () => {
  it("true for only-me with contributors present", () => {
    // The server checks contributors before the view scope.
    // Even after switching to "Only me", contributors keep seeing it.
    equal(leakyPrivate({ contributor_ids: ["a"] }, { mode: "me_only", accountIds: [] }), true);
  });

  it("false without contributors", () => {
    equal(leakyPrivate({ contributor_ids: [] }, { mode: "me_only", accountIds: [] }), false);
  });

  it("not a trap in other modes", () => {
    equal(
      leakyPrivate({ contributor_ids: ["a"] }, { mode: "assignees_only", accountIds: [] }),
      false,
    );
  });
});

describe("canManagePermissions", () => {
  it("reviewer only", () => {
    equal(canManagePermissions("reviewer"), true);
    equal(canManagePermissions("contributor"), false);
    equal(canManagePermissions("viewer"), false);
  });
});

describe("describeScope", () => {
  it("describes each mode differently", () => {
    equal(describeScope({ mode: "me_only", accountIds: [] }, 3), "Only me");
    equal(describeScope({ mode: "selected_friends", accountIds: ["a", "b"] }, 3), "2 friends");
    equal(describeScope({ mode: "selected_friends", accountIds: [] }, 3), "No friends selected");
    equal(describeScope({ mode: "all_friends", accountIds: [] }, 3), "All my friends (3)");
  });
});

describe("displayName", () => {
  const me: CurrentAccount = {
    id: "acct_me",
    email: "me@test.com",
    name: "Me",
  } as CurrentAccount;

  const friends: Friend[] = [
    { id: "acct_a", email: "a@test.com", name: "Alice Kim" } as Friend,
    { id: "acct_b", email: "b@test.com", name: "" } as Friend,
  ];

  it("finds a friend's name", () => {
    equal(displayName("acct_a", friends, me), "Alice Kim");
  });

  it("falls back to email without a name", () => {
    equal(displayName("acct_b", friends, me), "b@test.com");
  });

  it("shows me as Me", () => {
    equal(displayName("acct_me", friends, me), "Me");
  });

  it("unknown id is null — draw it removable, do not hide it", () => {
    equal(displayName("acct_missing", friends, me), null);
  });
});
