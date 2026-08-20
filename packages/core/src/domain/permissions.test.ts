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
  it("정상 값은 그대로", () => {
    for (const scope of VIEW_SCOPES) {
      equal(normalizeViewScope(scope.mode), scope.mode);
    }
  });

  it("sisyphus 값을 이 앱 값으로 옮긴다", () => {
    equal(normalizeViewScope("selected_members"), "selected_friends");
    equal(normalizeViewScope("project_members"), "all_friends");
    equal(normalizeViewScope("all_users"), "all_friends");
    equal(normalizeViewScope("private"), "me_only");
  });

  it("모르는 값은 기본값으로 좁힌다", () => {
    // 넓히는 쪽으로 기울면 옛 데이터 하나가 회의를 공개해 버린다
    equal(normalizeViewScope("아무거나"), "assignees_only");
    equal(normalizeViewScope(null), "assignees_only");
    equal(normalizeViewScope(42), "assignees_only");
  });
});

describe("readViewPermission", () => {
  it("어떤 모양이 와도 터지지 않는다", () => {
    deepEqual(readViewPermission(undefined), { mode: "assignees_only", accountIds: [] });
    deepEqual(readViewPermission(null), { mode: "assignees_only", accountIds: [] });
    deepEqual(readViewPermission({}), { mode: "assignees_only", accountIds: [] });
    deepEqual(readViewPermission({ view: {} }), { mode: "assignees_only", accountIds: [] });
    deepEqual(readViewPermission({ view: "글자" }), { mode: "assignees_only", accountIds: [] });
  });

  it("camelCase 와 snake_case 를 둘 다 읽는다", () => {
    // 서버 AccessLevel 도 둘 다 읽는다. 저장은 camelCase 로만 한다.
    deepEqual(readViewPermission({ view: { mode: "selected_friends", accountIds: ["a"] } }), {
      mode: "selected_friends",
      accountIds: ["a"],
    });

    deepEqual(readViewPermission({ view: { mode: "selected_friends", account_ids: ["a"] } }), {
      mode: "selected_friends",
      accountIds: ["a"],
    });
  });

  it("계정 id 가 아닌 값은 걸러낸다", () => {
    const result = readViewPermission({ view: { mode: "selected_friends", accountIds: ["a", 1, null] } });
    deepEqual(result.accountIds, ["a"]);
  });
});

describe("buildPermissions", () => {
  it("항상 두 키를 다 담는다", () => {
    // permissions_changeset 이 맵을 통째로 교체한다. 부분 전송은 곧 데이터 삭제다.
    const built = buildPermissions({ mode: "me_only", accountIds: [] });

    deepEqual(Object.keys(built.view).sort(), ["accountIds", "mode"]);
  });

  it("지정 모드가 아니면 대상 목록을 비운다", () => {
    for (const mode of ["me_only", "assignees_only", "all_friends"] as const) {
      deepEqual(buildPermissions({ mode, accountIds: ["a", "b"] }).view.accountIds, []);
    }
  });

  it("지정 모드에서는 목록을 유지한다", () => {
    deepEqual(
      buildPermissions({ mode: "selected_friends", accountIds: ["a", "b"] }).view.accountIds,
      ["a", "b"],
    );
  });

  it("키가 camelCase 다", () => {
    // snake_case 로 보내면 상세는 열리는데 목록 쿼리에 안 걸려 회의가 사라진다
    const json = JSON.stringify(buildPermissions({ mode: "selected_friends", accountIds: ["a"] }));

    ok(json.includes("accountIds"));
    ok(!json.includes("account_ids"));
  });
});

function ok(value: unknown) {
  equal(Boolean(value), true);
}

describe("leakyPrivate", () => {
  it("나만 + Contributor 가 있으면 참", () => {
    // 서버는 Contributor 검사를 공개 범위보다 먼저 한다.
    // "나만" 으로 바꿔도 Contributor 는 계속 본다.
    equal(leakyPrivate({ contributor_ids: ["a"] }, { mode: "me_only", accountIds: [] }), true);
  });

  it("Contributor 가 없으면 거짓", () => {
    equal(leakyPrivate({ contributor_ids: [] }, { mode: "me_only", accountIds: [] }), false);
  });

  it("다른 모드에서는 함정이 아니다", () => {
    equal(
      leakyPrivate({ contributor_ids: ["a"] }, { mode: "assignees_only", accountIds: [] }),
      false,
    );
  });
});

describe("canManagePermissions", () => {
  it("Reviewer 만", () => {
    equal(canManagePermissions("reviewer"), true);
    equal(canManagePermissions("contributor"), false);
    equal(canManagePermissions("viewer"), false);
  });
});

describe("describeScope", () => {
  it("모드마다 다르게 설명한다", () => {
    equal(describeScope({ mode: "me_only", accountIds: [] }, 3), "나만");
    equal(describeScope({ mode: "selected_friends", accountIds: ["a", "b"] }, 3), "친구 2명");
    equal(describeScope({ mode: "selected_friends", accountIds: [] }, 3), "지정한 친구 없음");
    equal(describeScope({ mode: "all_friends", accountIds: [] }, 3), "내 친구 전체 (3명)");
  });
});

describe("displayName", () => {
  const me: CurrentAccount = {
    id: "acct_me",
    email: "me@test.com",
    name: "나",
  } as CurrentAccount;

  const friends: Friend[] = [
    { id: "acct_a", email: "a@test.com", name: "김철수" } as Friend,
    { id: "acct_b", email: "b@test.com", name: "" } as Friend,
  ];

  it("친구 이름을 찾는다", () => {
    equal(displayName("acct_a", friends, me), "김철수");
  });

  it("이름이 없으면 이메일", () => {
    equal(displayName("acct_b", friends, me), "b@test.com");
  });

  it("나는 나로 표시한다", () => {
    equal(displayName("acct_me", friends, me), "나");
  });

  it("모르는 id 는 null — 화면에서 숨기지 말고 지울 수 있게 그린다", () => {
    equal(displayName("acct_없음", friends, me), null);
  });
});
