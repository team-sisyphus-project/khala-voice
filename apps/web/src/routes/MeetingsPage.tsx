import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { api } from "@/lib/api";
import { AppShell } from "@/components/AppShell";
import { MeetingDetailPage } from "@/routes/MeetingDetailPage";
import { Button, EmptyState, Notice } from "@/ui";

/**
 * The meetings tab = **record right away**.
 *
 * User requirement (2026-08-20): "Meetings means record now (opening a new
 * session); Archive is the list of meetings." So this screen draws no list —
 * the moment you enter, it opens a meeting and draws the recording screen in
 * place.
 *
 * **The address doesn't change.** It used to forward to
 * `/app/meetings/:id`, which turned the meetings tab into a depth screen
 * (with a back button) and broke the top-level tab grammar. Now the id is
 * held only in state and the address stays put.
 *
 * The list is [`ArchivePage`](./ArchivePage.tsx)'s job.
 */
export function MeetingsPage() {
  const { t } = useTranslation();
  const [meetingId, setMeetingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // StrictMode's double invocation must not create two empty meetings
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;

    void (async () => {
      try {
        setMeetingId(await openMeeting());
      } catch (e) {
        setError(e instanceof Error ? e.message : t("meetings.createError"));
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
        setError(e instanceof Error ? e.message : t("meetings.createError"));
      }
    })();
  }

  if (meetingId) return <MeetingDetailPage meetingId={meetingId} asTab />;

  return (
    <AppShell active="meetings" title={t("meetings.newTitle")} subtitle={t("meetings.newSubtitle")} center>
      {error ? (
        <>
          <Notice tone="error" title={t("meetings.problemTitle")}>
            {error}
          </Notice>
          <Button full icon="autorenew" onClick={retry}>
            {t("common.retry")}
          </Button>
        </>
      ) : (
        <EmptyState title={t("meetings.opening")} description={t("meetings.openingDesc")} />
      )}
    </AppShell>
  );
}

/**
 * Opens the meeting to record into.
 *
 * Creating a new one on every tab press piles **never-recorded empty
 * meetings** into the list (even mis-tapping and backing out creates one). So
 * if a just-created empty meeting exists, reopen it. The "record right away"
 * behavior is unchanged — either way the user lands straight on the recording
 * screen.
 */
async function openMeeting(): Promise<string> {
  try {
    const { meetings } = await api.listMeetings({ status: "active", limit: "5" });

    const empty = meetings.find(
      (m) => m.role === "reviewer" && (m.recording_sessions?.length ?? 0) === 0 && !m.summary,
    );

    if (empty) return empty.id;
  } catch {
    // Even if the list can't be read, recording must still start. Create a new one.
  }

  return (await api.createMeeting()).id;
}
