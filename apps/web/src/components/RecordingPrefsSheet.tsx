import { useCallback, useEffect, useState } from "react";
import { Recorder } from "@core/recorder";
import type { MicDevice } from "@core/recorder";
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
  const [devices, setDevices] = useState<MicDevice[]>([]);
  const [needsPermission, setNeeds] = useState(false);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);

    try {
      const result = await Recorder.listMicrophones();
      setDevices(result.devices);
      setNeeds(result.needsPermission);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();

    // 블루투스 헤드셋을 껐다 켜면 목록이 바뀐다
    const onChange = () => void load();
    navigator.mediaDevices?.addEventListener("devicechange", onChange);
    return () => navigator.mediaDevices?.removeEventListener("devicechange", onChange);
  }, [load]);

  async function grant() {
    await Recorder.requestPermission();
    await load();
  }

  return (
    <Sheet title="녹음 설정" onClose={onClose}>
      <div className="vr-filter">
        <LanguageField account={account} onChange={onAccountChange} />

        <span className="vr-filter__label">마이크</span>

        {needsPermission && (
          <>
            <p className="vr-note vr-note--small">
              장치 이름을 보려면 마이크 권한이 필요합니다. 권한을 준 뒤 목록이 채워집니다.
            </p>
            <Button icon="mic" onClick={() => void grant()}>
              마이크 권한 주기
            </Button>
          </>
        )}

        {loading && <p className="vr-note vr-note--small">찾는 중…</p>}

        {!loading && devices.length === 0 && (
          <p className="vr-note vr-note--small">쓸 수 있는 마이크를 찾지 못했습니다.</p>
        )}

        <div className="vr-scope">
          <MicOption
            label="기본 장치"
            hint="브라우저와 OS 가 고르는 마이크"
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
            완료
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
