import { useEffect, useRef, useState } from "react";
import { api } from "@/lib/api";
import { AppShell } from "@/components/AppShell";
import { MeetingDetailPage } from "@/routes/MeetingDetailPage";
import { Button, EmptyState, Notice } from "@/ui";

/**
 * 회의 탭 = **바로 녹음**.
 *
 * 사용자 요구(2026-08-20): "회의는 즉시 녹음(새 세션을 여는)거고,
 * 아카이브는 회의의 목록임." 그래서 이 화면은 목록을 그리지 않는다 —
 * 들어오는 순간 회의를 열고 녹음 화면을 그 자리에 그린다.
 *
 * **주소를 바꾸지 않는다.** 예전에는 `/app/meetings/:id` 로 넘겼는데, 그러면
 * 회의 탭이 뎁스 화면(뒤로가기 있는)으로 바뀌어 최상위 탭 문법이 깨졌다.
 * 지금은 id 를 상태로만 들고 같은 주소에 머문다.
 *
 * 목록은 [`ArchivePage`](./ArchivePage.tsx) 가 맡는다.
 */
export function MeetingsPage() {
  const [meetingId, setMeetingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // StrictMode 의 이중 실행으로 빈 회의가 두 개 생기면 안 된다
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;

    void (async () => {
      try {
        setMeetingId(await openMeeting());
      } catch (e) {
        setError(e instanceof Error ? e.message : "회의를 만들지 못했습니다");
      }
    })();
  }, []);

  function retry() {
    started.current = false;
    setError(null);

    void (async () => {
      started.current = true;

      try {
        setMeetingId(await openMeeting());
      } catch (e) {
        setError(e instanceof Error ? e.message : "회의를 만들지 못했습니다");
      }
    })();
  }

  if (meetingId) return <MeetingDetailPage meetingId={meetingId} asTab />;

  return (
    <AppShell active="meetings" title="새 회의" subtitle="녹음을 시작합니다" center>
      {error ? (
        <>
          <Notice tone="error" title="문제가 생겼습니다">
            {error}
          </Notice>
          <Button full icon="autorenew" onClick={retry}>
            다시 시도
          </Button>
        </>
      ) : (
        <EmptyState title="회의를 여는 중" description="잠시만 기다려 주세요." />
      )}
    </AppShell>
  );
}

/**
 * 녹음할 회의를 연다.
 *
 * 탭을 누를 때마다 새로 만들면 **한 번도 녹음하지 않은 빈 회의**가 목록에 쌓인다
 * (탭을 잘못 눌렀다 나오기만 해도 하나 생긴다). 그래서 방금 만든 빈 회의가
 * 있으면 그것을 다시 연다. "즉시 녹음"이라는 동작은 그대로다 — 사용자는
 * 어느 쪽이든 바로 녹음 화면을 본다.
 */
async function openMeeting(): Promise<string> {
  try {
    const { meetings } = await api.listMeetings({ status: "active", limit: "5" });

    const empty = meetings.find(
      (m) => m.role === "reviewer" && (m.recording_sessions?.length ?? 0) === 0 && !m.summary,
    );

    if (empty) return empty.id;
  } catch {
    // 목록을 못 봐도 녹음은 시작할 수 있어야 한다. 새로 만든다.
  }

  return (await api.createMeeting()).id;
}
