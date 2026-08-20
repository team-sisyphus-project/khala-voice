import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "@/lib/api";
import { Chip, EmptyState, Notice, Spinner } from "@/components/ui";
import { formatDateTime } from "@/lib/format";
import type { GrantedRole, Meeting, SharedLink } from "@core/api";
import { Sheet } from "@/ui";

/**
 * 공유 링크 관리. **Reviewer 에게만 보인다.**
 *
 * ## 평문은 한 번만 보여준다
 *
 * 서버 DB 에도 해시만 있어서 이 화면을 닫으면 다시 볼 수 없다.
 * 그 사실을 화면에 적어 둔다 — 모르고 닫으면 재발급밖에 방법이 없다.
 *
 * ## 링크만 만들면 게스트가 못 들어온다
 *
 * 회의의 `guest_link_enabled` 스위치가 꺼져 있으면 비로그인 방문자는 404 를 받는다.
 * 링크를 발급해 놓고 스위치를 안 켜면 "왜 안 되지" 가 되므로 여기서 함께 다룬다.
 */
export function ShareDialog({
  meeting,
  onClose,
  onMeetingChanged,
}: {
  meeting: Meeting;
  onClose: () => void;
  onMeetingChanged: () => void;
}) {
  const [links, setLinks] = useState<SharedLink[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  /** 발급 직후에만 채워진다. 목록을 새로 불러오면 사라진다. */
  const [issued, setIssued] = useState<SharedLink | null>(null);

  const [role, setRole] = useState<GrantedRole>("viewer");
  const [oneTime, setOneTime] = useState(false);
  const [withPincode, setWithPincode] = useState(false);
  const [expiresAt, setExpiresAt] = useState("");

  const load = useCallback(async () => {
    try {
      const { share_links } = await api.listShareLinks(meeting.id);
      setLinks(share_links);
    } catch (e) {
      setError(e instanceof Error ? e.message : "링크를 불러오지 못했습니다");
      setLinks([]);
    }
  }, [meeting.id]);

  useEffect(() => {
    void load();
  }, [load]);

  async function run(action: () => Promise<unknown>) {
    setBusy(true);
    setError(null);

    try {
      await action();
    } catch (e) {
      setError(e instanceof Error ? e.message : "처리하지 못했습니다");
    } finally {
      setBusy(false);
    }
  }

  const guestEnabled = meeting.guest_link_enabled;

  return (
    <Sheet title="공유 링크" onClose={onClose}>

        {error && <Notice kind="error" icon="error" className="mb-4">{error}</Notice>}

        {!guestEnabled && (
          <Notice kind="warn" icon="link_off" className="mb-4">
            이 회의는 <strong>게스트 접근이 꺼져 있습니다.</strong> 링크를 만들어도
            로그인하지 않은 사람은 열 수 없습니다.
            <button
              className="mobile-button mobile-button--primary mobile-button--fit"
              style={{ marginTop: 8, display: "block" }}
              disabled={busy}
              onClick={() =>
                void run(async () => {
                  await api.updateMeetingPermissions(meeting.id, { guest_link_enabled: true });
                  onMeetingChanged();
                })
              }
            >
              게스트 접근 켜기
            </button>
          </Notice>
        )}

        {issued && (
          <Notice kind="ok" icon="check_circle" className="mb-4">
            <strong>지금만 볼 수 있습니다.</strong> 이 창을 닫으면 다시 확인할 수 없습니다
            (서버에도 해시만 저장됩니다).
            <CopyRow label="링크" value={issued.url ?? ""} />
            {issued.pincode && <CopyRow label="PIN" value={issued.pincode} mono />}
          </Notice>
        )}

        <section className="vr-share__form">
          <div className="vr-filter__row">
            <span className="mobile-field__label">역할</span>
            {(["viewer", "contributor"] as GrantedRole[]).map((value) => (
              <button
                key={value}
                className={
                  role === value ? "mobile-button mobile-button--primary mobile-button--fit" : "mobile-button mobile-button--secondary mobile-button--fit"
                }
                aria-pressed={role === value}
                onClick={() => setRole(value)}
              >
                {/* 한국어 UI 에서도 영문 명칭 그대로 쓴다 */}
                {value === "viewer" ? "Viewer" : "Contributor"}
              </button>
            ))}
          </div>

          <p className="vr-note" style={{ fontSize: 12, margin: 0 }}>
            {role === "viewer"
              ? "읽기 전용입니다. 오디오 원본에는 접근할 수 없습니다."
              : "전사와 화자를 편집할 수 있습니다. 녹음·요약·삭제는 못 합니다."}
          </p>

          <div className="vr-filter__row">
            <Toggle checked={oneTime} onChange={setOneTime} label="1회만 사용" />
            <Toggle checked={withPincode} onChange={setWithPincode} label="PIN 걸기" />
          </div>

          <label style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
            <span className="mobile-field__label">만료</span>
            <input
              type="date"
              className="mobile-field__input"
              style={{ width: "auto", fontFamily: "var(--font-sans)" }}
              value={expiresAt}
              onChange={(e) => setExpiresAt(e.target.value)}
            />
            {expiresAt && (
              <button className="mobile-button mobile-button--ghost mobile-button--fit" onClick={() => setExpiresAt("")}>
                지우기
              </button>
            )}
          </label>

          <button
            className="mobile-button mobile-button--primary mobile-button--full"
            disabled={busy}
            onClick={() =>
              void run(async () => {
                const link = await api.createShareLink(meeting.id, {
                  granted_role: role,
                  max_uses: oneTime ? 1 : null,
                  with_pincode: withPincode,
                  // 그날 끝까지 유효하게 한다
                  expires_at: expiresAt ? `${expiresAt}T23:59:59Z` : null,
                });

                setIssued(link);
                await load();
              })
            }
          >
            링크 만들기
          </button>
        </section>

        <section style={{ marginTop: 16 }}>
          {links === null ? (
            <Spinner label="불러오는 중" />
          ) : links.length === 0 ? (
            <EmptyState icon="link" title="아직 발급한 링크가 없습니다" />
          ) : (
            <div style={{ display: "flex", flexDirection: "column" }}>
              {links.map((link) => (
                <LinkRow
                  key={link.id}
                  link={link}
                  busy={busy}
                  onRotate={() =>
                    void run(async () => {
                      const rotated = await api.rotateShareLink(link.id);
                      setIssued(rotated);
                      await load();
                    })
                  }
                  onRevoke={() =>
                    void run(async () => {
                      const ok = window.confirm(
                        "이 링크를 폐기하면 지금 이 링크로 보고 있는 사람도 즉시 끊깁니다. 계속할까요?",
                      );
                      if (!ok) return;
                      await api.deleteShareLink(link.id);
                      setIssued(null);
                      await load();
                    })
                  }
                />
              ))}
            </div>
          )}
        </section>
    </Sheet>
  );
}

function LinkRow({
  link,
  busy,
  onRotate,
  onRevoke,
}: {
  link: SharedLink;
  busy: boolean;
  onRotate: () => void;
  onRevoke: () => void;
}) {
  const exhausted = link.max_uses !== null && link.use_count >= link.max_uses;
  const expired = link.expires_at !== null && new Date(link.expires_at) < new Date();
  const dead = !link.is_active || exhausted || expired;

  return (
    <div className="vr-share__row">
      <div style={{ minWidth: 0, flex: 1 }}>
        <div style={{ display: "flex", gap: 6, alignItems: "center", flexWrap: "wrap" }}>
          <Chip kind={link.granted_role === "contributor" ? "info" : "neutral"}>
            {link.granted_role === "contributor" ? "Contributor" : "Viewer"}
          </Chip>
          {link.has_pincode && <Chip kind="neutral">PIN</Chip>}
          {link.max_uses === 1 && <Chip kind="neutral">1회용</Chip>}
          {dead && <Chip kind="warn">{expired ? "만료됨" : exhausted ? "사용됨" : "꺼짐"}</Chip>}
        </div>

        <div className="vr-note vr-note--small" style={{ marginTop: 4 }}>
          <code>{link.token_prefix}…</code>
          {" · "}
          {link.max_uses ? `${link.use_count}/${link.max_uses}회` : `${link.use_count}회 사용`}
          {link.expires_at && ` · ${formatDateTime(link.expires_at)}까지`}
        </div>
      </div>

      <button className="mobile-button mobile-button--secondary mobile-button--fit" onClick={onRotate} disabled={busy}>
        재발급
      </button>
      <button
        className="mobile-button mobile-button--ghost mobile-button--fit"
        style={{ color: "var(--status-error)" }}
        onClick={onRevoke}
        disabled={busy}
      >
        폐기
      </button>
    </div>
  );
}

function CopyRow({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  const [state, setState] = useState<"idle" | "copied" | "manual">("idle");
  const inputRef = useRef<HTMLInputElement>(null);

  /**
   * `navigator.clipboard` 는 보안 컨텍스트에서만 동작한다.
   * 막혀 있으면 **조용히 실패하지 않고** 텍스트를 선택해 준다 —
   * 사용자가 Ctrl+C 로 끝낼 수 있다. 아무 일도 안 일어나는 것이 최악이다.
   */
  async function copy() {
    inputRef.current?.select();

    try {
      await navigator.clipboard.writeText(value);
      setState("copied");
    } catch {
      setState("manual");
    }

    setTimeout(() => setState("idle"), 1800);
  }

  return (
    <div style={{ display: "flex", gap: 6, alignItems: "center", marginTop: 8 }}>
      <span className="mobile-field__label">{label}</span>
      <input
        ref={inputRef}
        className="mobile-field__input"
        readOnly
        value={value}
        aria-label={label}
        onFocus={(e) => e.currentTarget.select()}
        style={{ flex: 1, minWidth: 0, fontFamily: mono ? "var(--font-mono)" : "var(--font-sans)" }}
      />
      <button className="mobile-button mobile-button--secondary mobile-button--fit" onClick={() => void copy()}>
        {state === "copied" ? "복사됨" : state === "manual" ? "Ctrl+C" : "복사"}
      </button>
    </div>
  );
}

function Toggle({
  checked,
  onChange,
  label,
}: {
  checked: boolean;
  onChange: (value: boolean) => void;
  label: string;
}) {
  return (
    <button
      type="button"
      className={checked ? "mobile-button mobile-button--primary mobile-button--fit" : "mobile-button mobile-button--secondary mobile-button--fit"}
      aria-pressed={checked}
      onClick={() => onChange(!checked)}
    >
      {label}
    </button>
  );
}
