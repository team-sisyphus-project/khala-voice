import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { Recorder } from "@core/recorder";
import type { MicDevice, MicListResult, RecorderError } from "@core/recorder";
import { errorTitle, guideText } from "@/lib/recorderGuide";
import { Button, Icon, Sheet } from "@/ui";
import { LanguageField } from "@/components/LanguageField";
import type { CurrentAccount } from "@core/api";

/**
 * Recording preferences — microphone and transcription language.
 *
 * The engine supported device selection from the start
 * (`Recorder.listMicrophones` · `deviceId`), but the UI never surfaced it, so
 * recordings **always used the default device**. For meeting recordings that's
 * a silent failure — trying to capture a whole meeting room with a laptop's
 * built-in mic wrecks transcription quality, and the user can't tell why.
 *
 * The browser reveals device labels **only after permission is granted**. So
 * if labels are empty, ask for permission first.
 *
 * ## Don't show "Grant permission" while blocked
 *
 * Showing the button based only on empty labels means that on an **already
 * blocked** device, pressing it opens no prompt at all. The user assumes the
 * button is broken and keeps pressing. In that case, show the steps to unblock
 * on this device instead of the button.
 */
export function RecordingPrefsSheet({
  micDeviceId,
  account,
  onMicChange,
  onAccountChange,
  onClose,
}: {
  micDeviceId: string | null;
  account: CurrentAccount | null;
  onMicChange: (deviceId: string | null) => void;
  onAccountChange: (account: CurrentAccount) => void;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const [devices, setDevices] = useState<MicDevice[]>([]);
  const [needsPermission, setNeeds] = useState(false);
  const [trouble, setTrouble] = useState<
    Pick<RecorderError, "code" | "message" | "recovery"> | null
  >(null);
  const [loading, setLoading] = useState(true);

  const apply = useCallback((result: MicListResult) => {
    setDevices(result.devices);
    setNeeds(result.needsPermission);
    setTrouble(result.blocked ?? null);
  }, []);

  const load = useCallback(async () => {
    setLoading(true);

    try {
      apply(await Recorder.listMicrophones());
    } finally {
      setLoading(false);
    }
  }, [apply]);

  useEffect(() => {
    void load();

    // Toggling a Bluetooth headset off and on changes the list
    const onChange = () => void load();
    navigator.mediaDevices?.addEventListener("devicechange", onChange);

    // Unblocking from browser settings in another tab is picked up here instantly.
    // Without this, you'd have to close and reopen the sheet after fixing the setting.
    const stopWatching = Recorder.watchPermission(() => void load());

    return () => {
      navigator.mediaDevices?.removeEventListener("devicechange", onChange);
      stopWatching();
    };
  }, [load]);

  /**
   * Open the permission prompt.
   *
   * If a denial just quietly re-read the list, the screen would look like
   * nothing happened — leave the failure right there in place.
   */
  async function grant() {
    const result = await Recorder.requestPermission();

    if (!result.granted && result.error) {
      setTrouble(result.error);
      setNeeds(false);
      return;
    }

    await load();
  }

  return (
    <Sheet title={t("recordingPrefs.title")} onClose={onClose}>
      <div className="vr-filter">
        <LanguageField account={account} onChange={onAccountChange} />

        <span className="vr-filter__label">{t("recordingPrefs.micLabel")}</span>

        {needsPermission && !trouble && (
          <>
            <p className="vr-note vr-note--small">
              {t("recordingPrefs.permissionNote")}
            </p>
            <Button icon="mic" onClick={() => void grant()}>
              {t("recordingPrefs.grant")}
            </Button>
          </>
        )}

        {trouble && (
          <div className="vr-mic-trouble" role="alert">
            <p className="vr-mic-trouble__title">
              <Icon name="mic_off" />
              {errorTitle(t, trouble.code)}
            </p>
            <p className="vr-note vr-note--small">{guideText(t, trouble.message)}</p>

            {trouble.recovery && trouble.recovery.steps.length > 0 && (
              <ol className="vr-mic-trouble__steps">
                {trouble.recovery.steps.map((step) => (
                  <li key={step.key}>{guideText(t, step)}</li>
                ))}
              </ol>
            )}

            {/* Show the button only when asking again is possible — under a hard block, pressing opens nothing */}
            {trouble.recovery?.retryable && (
              <Button icon="mic" onClick={() => void grant()}>
                {t("common.retry")}
              </Button>
            )}
          </div>
        )}

        {loading && <p className="vr-note vr-note--small">{t("recordingPrefs.searching")}</p>}

        {!loading && devices.length === 0 && !trouble && (
          <p className="vr-note vr-note--small">{t("recordingPrefs.noneFound")}</p>
        )}

        <div className="vr-scope">
          <MicOption
            label={t("recordingPrefs.defaultDevice")}
            hint={t("recordingPrefs.defaultDeviceHint")}
            active={micDeviceId === null}
            onClick={() => onMicChange(null)}
          />

          {devices.map((device) => (
            <MicOption
              key={device.deviceId}
              // Labels are empty before permission — the "Microphone N" fallback
              // for that case is built by the shell, not core (core produces no locale copy).
              label={device.label || t("recordingPrefs.micFallback", { index: device.index })}
              active={micDeviceId === device.deviceId}
              onClick={() => onMicChange(device.deviceId)}
            />
          ))}
        </div>

        <div className="vr-filter__actions">
          <Button full onClick={onClose}>
            {t("common.done")}
          </Button>
        </div>
      </div>
    </Sheet>
  );
}

function MicOption({
  label,
  hint,
  active,
  onClick,
}: {
  label: string;
  hint?: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button type="button" className="vr-scope__option" data-active={active} onClick={onClick}>
      <span className="vr-scope__icon">
        <Icon name="mic" />
      </span>
      <span className="vr-scope__meta">
        <span className="vr-scope__name">{label}</span>
        {hint && <span className="vr-scope__hint">{hint}</span>}
      </span>
      {active && (
        <span className="vr-scope__check">
          <Icon name="check" />
        </span>
      )}
    </button>
  );
}
