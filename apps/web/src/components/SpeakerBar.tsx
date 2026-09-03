import { useState } from "react";
import { useTranslation } from "react-i18next";
import type { SpeakerView } from "@core/domain";
import { timeLabel } from "@core/domain";
import { Icon } from "@/ui";

/**
 * 화자 칩 줄.
 *
 * 칩을 고치면 **그 화자의 모든 발언**에 반영된다.
 * 한 줄만 고치려면 말풍선의 이름을 누른다.
 */
export function SpeakerBar({
  speakers,
  friends,
  canEdit,
  onRename,
  onAssign,
  onAdd,
  onRemove,
}: {
  speakers: SpeakerView[];
  friends: { id: string; name: string | null; email: string }[];
  canEdit: boolean;
  onRename: (key: string, name: string) => void;
  onAssign: (key: string, accountId: string | null) => void;
  onAdd: () => void;
  onRemove: (key: string) => void;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState<string | null>(null);

  if (speakers.length === 0) return null;

  return (
    <div className="vr-speakers">
      {speakers.map((speaker) => (
        <div key={speaker.key} style={{ position: "relative" }}>
          <button
            type="button"
            className="vr-speaker-chip"
            data-surface="control"
            data-speaker={speaker.colorIndex}
            onClick={() => canEdit && setOpen(open === speaker.key ? null : speaker.key)}
            disabled={!canEdit}
            title={t("speaker.segmentTitle", { count: speaker.segmentCount, time: timeLabel(speaker.totalMs) })}
          >
            <span className="vr-speaker-chip__dot" data-speaker={speaker.colorIndex} />
            {speaker.name}
            <span className="vr-speaker-chip__count">{speaker.segmentCount}</span>
          </button>

          {open === speaker.key && (
            <SpeakerMenu
              speaker={speaker}
              friends={friends}
              canRemove={speakers.length > 1}
              onRename={(name) => {
                onRename(speaker.key, name);
                setOpen(null);
              }}
              onAssign={(accountId) => {
                onAssign(speaker.key, accountId);
                setOpen(null);
              }}
              onRemove={() => {
                onRemove(speaker.key);
                setOpen(null);
              }}
              onClose={() => setOpen(null)}
            />
          )}
        </div>
      ))}

      {canEdit && (
        <button type="button" className="vr-speaker-chip vr-speaker-chip--add" onClick={onAdd}>
          <Icon name="add" />
          {t("speaker.addSpeaker")}
        </button>
      )}
    </div>
  );
}

function SpeakerMenu({
  speaker,
  friends,
  canRemove,
  onRename,
  onAssign,
  onRemove,
  onClose,
}: {
  speaker: SpeakerView;
  friends: { id: string; name: string | null; email: string }[];
  canRemove: boolean;
  onRename: (name: string) => void;
  onAssign: (accountId: string | null) => void;
  onRemove: () => void;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const [name, setName] = useState(speaker.name);

  return (
    <>
      {/* 바깥을 눌러 닫는다 */}
      <div className="vr-menu__backdrop" onClick={onClose} />

      <div className="vr-menu" data-surface="raised">
        <label className="mobile-field__label" style={{ marginBottom: 6 }}>{t("speaker.name")}</label>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            onRename(name.trim() || speaker.name);
          }}
          style={{ display: "flex", gap: 6 }}
        >
          <input
            className="mobile-field__input"
            data-surface="sunken"
            value={name}
            onChange={(e) => setName(e.target.value)}
            autoFocus
            style={{ fontFamily: "var(--font-sans)", flex: 1, minWidth: 0 }}
          />
          <button type="submit" className="mobile-button mobile-button--primary mobile-button--fit">
            {t("common.save")}
          </button>
        </form>

        {friends.length > 0 && (
          <>
            <div className="vr-menu__title">{t("speaker.linkFriend")}</div>
            <div className="vr-menu__list">
              <button
                type="button"
                className="vr-menu__item"
                onClick={() => onAssign(null)}
                data-active={speaker.accountId === null}
              >
                {t("speaker.unlinked")}
              </button>
              {friends.map((friend) => (
                <button
                  key={friend.id}
                  type="button"
                  className="vr-menu__item"
                  onClick={() => onAssign(friend.id)}
                  data-active={speaker.accountId === friend.id}
                >
                  {friend.name || friend.email}
                </button>
              ))}
            </div>
          </>
        )}

        {canRemove && (
          <button
            type="button"
            className="mobile-button mobile-button--ghost mobile-button--fit"
            style={{ color: "var(--status-error)", marginTop: 8, width: "100%" }}
            onClick={onRemove}
          >
            {t("speaker.removeSpeaker")}
          </button>
        )}
      </div>
    </>
  );
}
