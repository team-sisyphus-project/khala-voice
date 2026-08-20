import { useState } from "react";
import { api } from "@/lib/api";
import { Icon } from "@/ui";
import { Notice } from "@/components/ui";
import { FriendPicker, FriendTokens } from "@/components/FriendPicker";
import {
  buildPermissions,
  canManagePermissions,
  displayName,
  leakyPrivate,
  readViewPermission,
  VIEW_SCOPES,
} from "@core/domain";
import type { ViewScopeMode } from "@core/domain";
import type { CurrentAccount, Friend, Meeting } from "@core/api";

/**
 * 공개 범위 · Reviewer · Contributor 설정. **Reviewer 만 본다.**
 *
 * **출처: sisyphus** `assets/webapp/meeting-recorder.js` 의 공개범위 편집 popover.
 * 바꾼 것:
 * - popover → **인라인 라디오 리스트.** 선택지가 4개뿐이고 각 설명이 판단의 핵심이라
 *   접으면 안 된다. 접으면 고른 뒤에야 다른 선택지의 뜻을 보게 되어 오설정을 부른다
 * - 라벨을 Reviewer / Contributor / Viewer 영문 그대로 (원본은 "검토자"·"관계자")
 * - **"나만" 함정 경고** — 원본에 없다
 * - **Reviewer 양도 확인과 이탈 처리** — 원본에 없다
 */
export function VisibilityPanel({
  meeting,
  friends,
  me,
  onSaved,
  onError,
  onLostAccess,
}: {
  meeting: Meeting;
  friends: Friend[];
  me: CurrentAccount | null;
  onSaved: (meeting: Meeting) => void;
  onError: (message: string | null) => void;
  onLostAccess: () => void;
}) {
  const [saving, setSaving] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [transferTo, setTransferTo] = useState<string | null>(null);
  const [keepMeAsContributor, setKeepMe] = useState(true);

  // `permissions` 부재는 서버가 lv0 이 아니라고 판정했다는 직접 증거다 —
  // JSONView 가 lv0 에게만 넣는다. 탭 조건과 여기, 두 곳에서 막는다.
  if (!canManagePermissions(meeting.role) || !meeting.permissions) return null;

  const view = readViewPermission(meeting.permissions);
  const noFriends = friends.length === 0;

  /**
   * 저장한다. **낙관적 갱신을 하지 않는다.**
   *
   * 전사 편집은 낙관적으로 그리지만 여기는 다르다. 권한은 틀린 상태를 잠깐이라도
   * 보여주면 안 된다 — "공개했다"고 보이는데 실제로는 실패해 비공개인 상황과
   * 그 반대가 모두 위험하다. 서버 응답만 신뢰한다.
   * (일관성을 이유로 이걸 낙관적 갱신으로 되돌리지 말 것.)
   */
  async function save(body: Record<string, unknown>, opts: { transfer?: boolean } = {}) {
    setSaving(true);
    setStatus("저장 중…");
    onError(null);

    try {
      const updated = await api.updateMeetingPermissions(meeting.id, body);
      onSaved(updated);
      setStatus("저장했습니다");

      // 양도했으면 이 화면을 더 볼 수 없다. 처리하지 않으면 다음 폴링에서
      // 404 를 맞고 화면이 깨진다.
      if (opts.transfer && updated.role !== "reviewer") onLostAccess();
    } catch (e) {
      setStatus(null);
      onError(e instanceof Error ? e.message : "저장하지 못했습니다");
    } finally {
      setSaving(false);
      setTransferTo(null);
    }
  }

  function changeMode(mode: ViewScopeMode) {
    if (mode === view.mode) return;
    void save({ permissions: buildPermissions({ mode, accountIds: view.accountIds }) });
  }

  function setSelectedFriends(ids: string[]) {
    void save({ permissions: buildPermissions({ mode: "selected_friends", accountIds: ids }) });
  }

  return (
    <section style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <div>
        <h3 className="mobile-section__title">공개 범위</h3>
        <p className="vr-note" style={{ fontSize: 12, margin: "2px 0 10px" }}>
          Reviewer 와 Contributor 는 여기 설정과 상관없이 항상 볼 수 있습니다.
        </p>

        <div className="vr-scope" role="radiogroup" aria-label="공개 범위">
          {VIEW_SCOPES.map((scope) => {
            const blocked = scope.needsFriends && noFriends;

            return (
              <button
                key={scope.mode}
                type="button"
                role="radio"
                aria-checked={view.mode === scope.mode}
                className="vr-scope__option"
                data-active={view.mode === scope.mode}
                disabled={saving || blocked}
                onClick={() => changeMode(scope.mode)}
              >
                <span className="vr-scope__icon"><Icon name={scope.icon} /></span>
                <span className="vr-scope__meta">
                  <span className="vr-scope__name">
                    {scope.label}
                    {scope.mode === "assignees_only" && (
                      <span className="vr-chip vr-chip--neutral" style={{ marginLeft: 6 }}>기본</span>
                    )}
                  </span>
                  <span className="vr-scope__hint">
                    {blocked ? "친구를 추가하면 쓸 수 있습니다" : scope.hint}
                  </span>
                </span>
                {view.mode === scope.mode && (
                  <span className="vr-scope__check"><Icon name="check" /></span>
                )}
              </button>
            );
          })}
        </div>

        {noFriends && (
          <p className="vr-note" style={{ fontSize: 12, marginTop: 8 }}>
            <a href="/friends">친구 추가하기</a>
          </p>
        )}
      </div>

      {view.mode === "selected_friends" && (
        <div>
          <FriendTokens
            ids={view.accountIds}
            friends={friends}
            me={me}
            disabled={saving}
            onRemove={(id) => setSelectedFriends(view.accountIds.filter((x) => x !== id))}
          />

          <div style={{ marginTop: 8 }}>
            <FriendPicker
              friends={friends}
              me={me}
              selected={view.accountIds}
              multiple
              disabled={saving}
              label="친구 고르기"
              onChange={setSelectedFriends}
            />
          </div>

          {view.accountIds.length === 0 && (
            <Notice kind="warn" icon="info" className="mt-2">
              아직 아무도 고르지 않았습니다 — 지금은 Reviewer 와 Contributor 만 볼 수 있습니다.
            </Notice>
          )}
        </div>
      )}

      {view.mode === "all_friends" && (
        <p className="vr-note" style={{ fontSize: 12 }}>
          지금 {friends.length}명입니다. 친구가 늘면 자동으로 포함됩니다.
        </p>
      )}

      {/* 서버는 Contributor 검사를 공개 범위보다 먼저 한다 (access_level.ex 의 cond 순서).
          "나만" 으로 바꿔도 Contributor 는 계속 본다 — 사용자는 비공개로 만들었다고 믿는다. */}
      {leakyPrivate(meeting, view) && (
        <Notice kind="warn" icon="warning">
          <strong>Contributor 는 계속 볼 수 있습니다.</strong> Contributor 로 지정된{" "}
          {meeting.contributor_ids.length}명은 공개 범위와 상관없이 이 회의에 접근합니다.
          완전히 비공개로 하려면 Contributor 를 모두 해제하세요.
          <button
            className="mobile-button mobile-button--secondary mobile-button--fit"
            style={{ display: "block", marginTop: 8 }}
            disabled={saving}
            onClick={() => void save({ contributor_ids: [] })}
          >
            Contributor 모두 해제
          </button>
        </Notice>
      )}

      <hr style={{ border: 0, borderTop: "var(--hairline-width) solid var(--border-subtle)" }} />

      <div>
        <h3 className="mobile-section__title">Contributor</h3>
        <p className="vr-note" style={{ fontSize: 12, margin: "2px 0 8px" }}>
          녹음 · 전사 편집 · 요약을 할 수 있습니다. 삭제와 권한 변경은 못 합니다.
        </p>

        <FriendTokens
          ids={meeting.contributor_ids}
          friends={friends}
          me={me}
          disabled={saving}
          onRemove={(id) =>
            void save({ contributor_ids: meeting.contributor_ids.filter((x) => x !== id) })
          }
        />

        <div style={{ marginTop: 8 }}>
          <FriendPicker
            friends={friends}
            me={me}
            selected={meeting.contributor_ids}
            multiple
            disabled={saving}
            label="Contributor 지정"
            onChange={(ids) => void save({ contributor_ids: ids })}
          />
        </div>
      </div>

      <div>
        <h3 className="mobile-section__title">Reviewer 양도</h3>
        <p className="vr-note" style={{ fontSize: 12, margin: "2px 0 8px" }}>
          전권을 넘깁니다. 넘기고 나면 되돌릴 수 없습니다.
        </p>

        {transferTo ? (
          <Notice kind="warn" icon="warning">
            <strong>Reviewer 를 넘기시겠습니까?</strong>{" "}
            {displayName(transferTo, friends, me) ?? "이 사람"} 님이 이 회의의 전권을 갖게 되고,
            나는 공개 범위를 더 이상 바꿀 수 없습니다.
            {view.mode === "all_friends" && (
              <>
                {" "}
                공개 범위가 <strong>내 친구 전체</strong>입니다 — 넘기면 공개 대상이 그 사람의
                친구 목록으로 바뀝니다.
              </>
            )}
            <label style={{ display: "flex", gap: 6, alignItems: "center", marginTop: 10 }}>
              <input
                type="checkbox"
                checked={keepMeAsContributor}
                onChange={(e) => setKeepMe(e.target.checked)}
              />
              나를 Contributor 로 남기기 (해제하면 이 회의를 못 보게 됩니다)
            </label>
            <div style={{ display: "flex", gap: 6, marginTop: 10 }}>
              <button
                className="mobile-button mobile-button--primary mobile-button--fit"
                disabled={saving}
                onClick={() => {
                  const next = new Set(meeting.contributor_ids);
                  // 새 Reviewer 를 Contributor 에서 뺀다 — 역할이 겹칠 이유가 없다
                  next.delete(transferTo);
                  if (keepMeAsContributor && me) next.add(me.id);

                  void save(
                    { reviewer_id: transferTo, contributor_ids: [...next] },
                    { transfer: true },
                  );
                }}
              >
                넘기기
              </button>
              <button
                className="mobile-button mobile-button--ghost mobile-button--fit"
                onClick={() => setTransferTo(null)}
              >
                취소
              </button>
            </div>
          </Notice>
        ) : (
          <FriendPicker
            friends={friends}
            me={me}
            selected={[]}
            disabled={saving}
            label="Reviewer 넘기기"
            onChange={(ids) => setTransferTo(ids[0] ?? null)}
          />
        )}
      </div>

      <p className="vr-note" style={{ fontSize: 12, minHeight: 16 }} aria-live="polite">
        {status}
      </p>
    </section>
  );
}
