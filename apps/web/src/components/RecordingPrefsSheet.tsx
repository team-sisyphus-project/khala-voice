import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { Recorder, micErrorTitle } from "@core/recorder";
import type { MicDevice, MicListResult, RecorderError } from "@core/recorder";
import { Button, Icon, Sheet } from "@/ui";
import { LanguageField } from "@/components/LanguageField";
import type { CurrentAccount } from "@core/api";

/**
 * 녹음 설정 — 마이크와 전사 언어.
 *
 * 엔진은 처음부터 장치 선택을 지원했는데(`Recorder.listMicrophones` · `deviceId`)
 * 화면이 그걸 꺼내 쓰지 않아 **늘 기본 장치로만** 녹음됐다. 회의 녹음에서
 * 이건 조용한 실패다 — 노트북 내장 마이크로 회의실 전체를 담으려다
 * 전사 품질이 무너져도 사용자는 이유를 알 수 없다.
 *
 * 장치 라벨은 **권한을 준 뒤에만** 브라우저가 알려준다. 그래서 라벨이 비어 있으면
 * 권한부터 받는다.
 *
 * ## 차단된 상태에서는 "권한 주기" 를 띄우지 않는다
 *
 * 라벨이 비었다는 사실만 보고 버튼을 띄우면, **이미 차단된** 기기에서는 눌러도
 * 아무 창이 뜨지 않는다. 사용자는 버튼이 고장 난 줄 알고 계속 누른다.
 * 그 경우에는 버튼 대신 이 기기에서 차단을 푸는 절차를 보여준다.
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

    // 블루투스 헤드셋을 껐다 켜면 목록이 바뀐다
    const onChange = () => void load();
    navigator.mediaDevices?.addEventListener("devicechange", onChange);

    // 다른 탭의 브라우저 설정에서 차단을 풀면 이쪽도 즉시 따라간다.
    // 이게 없으면 설정을 고쳐 놓고도 시트를 닫았다 열어야 한다.
    const stopWatching = Recorder.watchPermission(() => void load());

    return () => {
      navigator.mediaDevices?.removeEventListener("devicechange", onChange);
      stopWatching();
    };
  }, [load]);

  /**
   * 권한 창을 띄운다.
   *
   * 거절당했을 때 조용히 목록만 다시 읽으면 화면은 아무 일도 없었던 것처럼
   * 보인다 — 실패를 그 자리에 남긴다.
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
              {micErrorTitle(trouble.code)}
            </p>
            <p className="vr-note vr-note--small">{trouble.message}</p>

            {trouble.recovery && trouble.recovery.steps.length > 0 && (
              <ol className="vr-mic-trouble__steps">
                {trouble.recovery.steps.map((step) => (
                  <li key={step}>{step}</li>
                ))}
              </ol>
            )}

            {/* 다시 물어볼 수 있을 때만 버튼을 둔다 — 굳은 차단에서는 눌러도 창이 안 뜬다 */}
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
              label={device.label}
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
