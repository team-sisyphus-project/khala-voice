import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { displayName } from "@core/domain";
import type { CurrentAccount, Friend } from "@core/api";
import { Icon } from "@/ui";

/**
 * Friend picker.
 *
 * **Source: sisyphus** — the member picker in
 * `assets/shared/components/core-ui.js`. Changed member → friend, and
 * multi-select saves **once, when the menu closes**.
 *
 * ## Why save on close
 *
 * Saving on every check sends three PATCHes for three checks, and the next
 * one departs before the previous finishes, getting swallowed by the `saving`
 * guard. The result: the user's final selection sometimes never saves.
 *
 * Single-select does the opposite and saves immediately — the intent is
 * complete the moment you pick.
 */
export function FriendPicker({
  friends,
  me,
  selected,
  multiple = false,
  disabled,
  label,
  onChange,
}: {
  friends: Friend[];
  me: CurrentAccount | null;
  selected: string[];
  multiple?: boolean;
  disabled?: boolean;
  label: string;
  onChange: (ids: string[]) => void;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState<string[]>(selected);
  const committed = useRef<string[]>(selected);

  // **The value read on close lives in a ref.** With state alone, `close()`
  // sees the render closure's stale value — check something and press "Done"
  // immediately (before React re-renders) and the last selection vanishes.
  const draftRef = useRef<string[]>(selected);

  // Sync only when the **contents** change.
  //
  // `selected` may be an array rebuilt on every render at the call site
  // (`readViewPermission` does this). Using the array reference as a
  // dependency loops forever: render → effect → setState → render.
  const selectedKey = selected.join(",");

  useEffect(() => {
    if (open) return;

    const next = selectedKey ? selectedKey.split(",") : [];
    setDraft(next);
    draftRef.current = next;
    committed.current = next;
  }, [selectedKey, open]);

  function close() {
    setOpen(false);

    if (!multiple) return;

    const latest = draftRef.current;
    if (sameSet(latest, committed.current)) return;

    committed.current = latest;
    onChange(latest);
  }

  function toggle(id: string) {
    if (!multiple) {
      setOpen(false);
      onChange([id]);
      return;
    }

    const next = draftRef.current.includes(id)
      ? draftRef.current.filter((x) => x !== id)
      : [...draftRef.current, id];

    draftRef.current = next;
    setDraft(next);
  }

  const current = open && multiple ? draft : selected;

  return (
    <div style={{ position: "relative" }}>
      <button
        type="button"
        className="mobile-button mobile-button--secondary mobile-button--fit"
        onClick={() => (open ? close() : setOpen(true))}
        disabled={disabled || friends.length === 0}
        aria-expanded={open}
      >
        <Icon name="person_add" />
        {label}
      </button>

      {open && (
        <>
          <div className="vr-menu__backdrop" onClick={close} />
          <div className="vr-menu vr-menu--inline" role="listbox" aria-multiselectable={multiple}>
            <div className="vr-menu__title">{t("friends.title")}</div>
            <div className="vr-menu__list">
              {friends.map((friend) => {
                const active = current.includes(friend.id);

                return (
                  <button
                    key={friend.id}
                    type="button"
                    role="option"
                    aria-selected={active}
                    className="vr-menu__item"
                    data-active={active}
                    onClick={() => toggle(friend.id)}
                  >
                    {multiple && (
                      <Icon name={active ? "check_box" : "check_box_outline_blank"} />
                    )}
                    {displayName(friend.id, friends, me) ?? friend.email}
                  </button>
                );
              })}
            </div>

            {multiple && (
              <button type="button" className="mobile-button mobile-button--primary mobile-button--fit" onClick={close}>
                {t("common.done")}
              </button>
            )}
          </div>
        </>
      )}
    </div>
  );
}

/** Selected people as tokens. ✕ saves **immediately** even in multi-select — removal is unambiguous intent. */
export function FriendTokens({
  ids,
  friends,
  me,
  disabled,
  onRemove,
}: {
  ids: string[];
  friends: Friend[];
  me: CurrentAccount | null;
  disabled?: boolean;
  onRemove: (id: string) => void;
}) {
  const { t } = useTranslation();
  if (ids.length === 0) return null;

  return (
    <div className="vr-tokens">
      {ids.map((id) => {
        const name = displayName(id, friends, me);

        return (
          <span key={id} className="vr-token" data-unknown={name === null || undefined}>
            {/* A stale id left after unfriending. Hidden, it could never be removed and would linger forever. */}
            {name ?? t("friends.unknownUser")}
            <button
              type="button"
              className="vr-token__x"
              onClick={() => onRemove(id)}
              disabled={disabled}
              aria-label={t("friends.removeAria", { name: name ?? id })}
            >
              <Icon name="close" />
            </button>
          </span>
        );
      })}
    </div>
  );
}

function sameSet(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  const set = new Set(b);
  return a.every((x) => set.has(x));
}
