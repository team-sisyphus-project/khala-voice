import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { displayName } from "@core/domain";
import type { CurrentAccount, Friend } from "@core/api";
import { Icon } from "@/ui";

/**
 * 친구 고르기.
 *
 * **출처: sisyphus** `assets/shared/components/core-ui.js` 의 멤버 피커.
 * member → friend 로 바꾸고, 다중 선택은 **메뉴가 닫힐 때 한 번만** 저장한다.
 *
 * ## 왜 닫힐 때 저장하나
 *
 * 체크할 때마다 저장하면 세 번 체크에 PATCH 세 번이 나가고, 앞선 요청이 끝나기 전에
 * 다음이 출발해 `saving` 가드에 씹힌다. 결과적으로 사용자가 고른 마지막 상태가
 * 저장되지 않는 일이 생긴다.
 *
 * 단일 선택은 반대로 즉시 저장한다 — 고르는 순간 의도가 끝나기 때문이다.
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

  // **닫을 때 읽을 값은 ref 에 둔다.** state 만 쓰면 `close()` 가 렌더 클로저의
  // 옛 값을 본다 — 체크한 뒤 곧바로 "완료" 를 누르면(React 가 다시 그리기 전)
  // 마지막 선택이 통째로 사라진다.
  const draftRef = useRef<string[]>(selected);

  // **내용**이 바뀔 때만 동기화한다.
  //
  // `selected` 는 호출부에서 매 렌더 새로 만들어지는 배열일 수 있다
  // (`readViewPermission` 이 그렇다). 배열 참조를 의존성에 그대로 쓰면
  // 렌더 → 이펙트 → setState → 렌더 로 무한히 돈다.
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

/** 고른 사람을 토큰으로. ✕ 는 다중에서도 **즉시** 저장한다 — 제거는 의도가 분명하다. */
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
            {/* 친구를 끊은 뒤 남은 옛 id. 숨기면 지울 수도 없어 영원히 남는다. */}
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
