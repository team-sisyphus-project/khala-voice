import { useState } from "react";
import { Trans, useTranslation } from "react-i18next";
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
 * Visibility · Reviewer · Contributor settings. **Reviewers only.**
 *
 * **Source: sisyphus** — the visibility-editing popover in
 * `assets/webapp/meeting-recorder.js`. What changed:
 * - popover → **inline radio list.** There are only 4 options and each
 *   description is central to the decision, so they must not be folded away.
 *   Folded, you only see what the other options meant after picking — inviting
 *   misconfiguration
 * - Labels kept as the English Reviewer / Contributor / Viewer (the original
 *   used localized terms)
 * - **The "Only me" trap warning** — not in the original
 * - **Reviewer transfer confirmation and lost-access handling** — not in the original
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
  const { t } = useTranslation();
  const [saving, setSaving] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [transferTo, setTransferTo] = useState<string | null>(null);
  const [keepMeAsContributor, setKeepMe] = useState(true);

  // A missing `permissions` is direct evidence the server judged this not-lv0 —
  // JSONView includes it only for lv0. Guarded both at the tab condition and here.
  if (!canManagePermissions(meeting.role) || !meeting.permissions) return null;

  const view = readViewPermission(meeting.permissions);
  const noFriends = friends.length === 0;

  /**
   * Save. **No optimistic updates.**
   *
   * Transcript edits render optimistically, but this is different. Permissions
   * must never show a wrong state even briefly — "looks shared" while the save
   * actually failed and it's private, and the reverse, are both dangerous.
   * Trust only the server response.
   * (Do not revert this to optimistic updates for consistency's sake.)
   */
  async function save(body: Record<string, unknown>, opts: { transfer?: boolean } = {}) {
    setSaving(true);
    setStatus(t("visibility.saving"));
    onError(null);

    try {
      const updated = await api.updateMeetingPermissions(meeting.id, body);
      onSaved(updated);
      setStatus(t("visibility.saved"));

      // After a transfer, this screen can no longer be viewed. Unhandled, the
      // next poll hits a 404 and the screen breaks.
      if (opts.transfer && updated.role !== "reviewer") onLostAccess();
    } catch (e) {
      setStatus(null);
      onError(e instanceof Error ? e.message : t("common.saveError"));
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
        <h3 className="mobile-section__title">{t("visibility.scopeTitle")}</h3>
        <p className="vr-note" style={{ fontSize: 12, margin: "2px 0 10px" }}>
          {t("visibility.scopeNote")}
        </p>

        <div className="vr-scope" role="radiogroup" aria-label={t("visibility.scopeAria")}>
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
                    {t(`visibility.scopes.${scope.mode}.label`)}
                    {scope.mode === "assignees_only" && (
                      <span className="vr-chip vr-chip--neutral" style={{ marginLeft: 6 }}>{t("visibility.defaultChip")}</span>
                    )}
                  </span>
                  <span className="vr-scope__hint">
                    {blocked ? t("visibility.needsFriends") : t(`visibility.scopes.${scope.mode}.hint`)}
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
            <a href="/friends">{t("visibility.addFriends")}</a>
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
              label={t("visibility.pickFriends")}
              onChange={setSelectedFriends}
            />
          </div>

          {view.accountIds.length === 0 && (
            <Notice kind="warn" icon="info" className="mt-2">
              {t("visibility.noneSelected")}
            </Notice>
          )}
        </div>
      )}

      {view.mode === "all_friends" && (
        <p className="vr-note" style={{ fontSize: 12 }}>
          {t("visibility.allFriendsCount", { count: friends.length })}
        </p>
      )}

      {/* The server checks Contributor before visibility (the cond order in access_level.ex).
          Even switched to "Only me", Contributors keep seeing it — while the user believes it's private. */}
      {leakyPrivate(meeting, view) && (
        <Notice kind="warn" icon="warning">
          <strong>{t("visibility.leakyTitle")}</strong>{" "}
          {t("visibility.leakyBody", { count: meeting.contributor_ids.length })}
          <button
            className="mobile-button mobile-button--secondary mobile-button--fit"
            style={{ display: "block", marginTop: 8 }}
            disabled={saving}
            onClick={() => void save({ contributor_ids: [] })}
          >
            {t("visibility.clearContributors")}
          </button>
        </Notice>
      )}

      <hr style={{ border: 0, borderTop: "var(--hairline-width) solid var(--border-subtle)" }} />

      <div>
        <h3 className="mobile-section__title">{t("visibility.contributorTitle")}</h3>
        <p className="vr-note" style={{ fontSize: 12, margin: "2px 0 8px" }}>
          {t("visibility.contributorNote")}
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
            label={t("visibility.assignContributor")}
            onChange={(ids) => void save({ contributor_ids: ids })}
          />
        </div>
      </div>

      <div>
        <h3 className="mobile-section__title">{t("visibility.transferTitle")}</h3>
        <p className="vr-note" style={{ fontSize: 12, margin: "2px 0 8px" }}>
          {t("visibility.transferNote")}
        </p>

        {transferTo ? (
          <Notice kind="warn" icon="warning">
            <strong>{t("visibility.transferConfirmTitle")}</strong>{" "}
            {t("visibility.transferConfirmBody", {
              name: displayName(transferTo, friends, me) ?? t("visibility.transferThisPerson"),
            })}
            {view.mode === "all_friends" && (
              <>
                {" "}
                <Trans t={t} i18nKey="visibility.transferAllFriends" components={{ strong: <strong /> }} />
              </>
            )}
            <label style={{ display: "flex", gap: 6, alignItems: "center", marginTop: 10 }}>
              <input
                type="checkbox"
                checked={keepMeAsContributor}
                onChange={(e) => setKeepMe(e.target.checked)}
              />
              {t("visibility.keepMeContributor")}
            </label>
            <div style={{ display: "flex", gap: 6, marginTop: 10 }}>
              <button
                className="mobile-button mobile-button--primary mobile-button--fit"
                disabled={saving}
                onClick={() => {
                  const next = new Set(meeting.contributor_ids);
                  // Remove the new Reviewer from Contributors — no reason for the roles to overlap
                  next.delete(transferTo);
                  if (keepMeAsContributor && me) next.add(me.id);

                  void save(
                    { reviewer_id: transferTo, contributor_ids: [...next] },
                    { transfer: true },
                  );
                }}
              >
                {t("visibility.transferConfirm")}
              </button>
              <button
                className="mobile-button mobile-button--ghost mobile-button--fit"
                onClick={() => setTransferTo(null)}
              >
                {t("common.cancel")}
              </button>
            </div>
          </Notice>
        ) : (
          <FriendPicker
            friends={friends}
            me={me}
            selected={[]}
            disabled={saving}
            label={t("visibility.transferPick")}
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
