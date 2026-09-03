/**
 * Transcript and speaker operations.
 *
 * **Source: sisyphus** `assets/webapp/meeting-recorder.js` 2416~3470,
 * 5362~5960 — logic extracted, UI dependencies removed.
 *
 * ## Speakers are two-layered
 *
 *     transcript.segments[i].speaker  =  "speaker_1"          ← raw STT, per segment
 *     speaker_map["speaker_1"]        =  { name, account_id } ← person mapping, per speaker
 *
 * It is tempting to merge the two, but they are **different operations**.
 *
 * - Changing a speaker chip → `speaker_map` → applies to **all** of that speaker's lines
 * - Changing a segment avatar → `segments[i].speaker` → **that one line only**
 *
 * The second is for when STT mis-split speakers. Merging would make it impossible.
 */

import type { SpeakerMapEntry, Transcript, TranscriptSegment } from "../api/types";

export interface SpeakerView {
  /** Raw key like `speaker_1` */
  key: string;
  /** Name shown on screen */
  name: string;
  accountId: string | null;
  /** Number of utterances by this speaker */
  segmentCount: number;
  /** Total speaking time of this speaker (ms) */
  totalMs: number;
  /** Palette index (1~10). Fixed by order of appearance */
  colorIndex: number;
}

export const SPEAKER_COLOR_COUNT = 10;

/**
 * Speaker list for rendering.
 *
 * **Colors are fixed by order of appearance.** Renaming must keep the color,
 * so the user does not lose "the blue person from before".
 */
export function speakerViews(
  transcript: Transcript | null,
  speakerMap: Record<string, SpeakerMapEntry>,
): SpeakerView[] {
  const segments = transcript?.segments ?? [];
  const order: string[] = [];
  const stats = new Map<string, { count: number; ms: number }>();

  for (const segment of segments) {
    if (!stats.has(segment.speaker)) {
      order.push(segment.speaker);
      stats.set(segment.speaker, { count: 0, ms: 0 });
    }
    const entry = stats.get(segment.speaker)!;
    entry.count += 1;
    entry.ms += Math.max(0, segment.end_ms - segment.start_ms);
  }

  // Speakers with zero utterances still show if they are in the map (user-added)
  for (const key of Object.keys(speakerMap)) {
    if (!stats.has(key)) {
      order.push(key);
      stats.set(key, { count: 0, ms: 0 });
    }
  }

  return order.map((key, index) => {
    const mapped = speakerMap[key];
    const entry = stats.get(key)!;

    return {
      key,
      name: mapped?.name || fallbackName(key),
      accountId: mapped?.account_id ?? null,
      segmentCount: entry.count,
      totalMs: entry.ms,
      colorIndex: (index % SPEAKER_COLOR_COUNT) + 1,
    };
  });
}

function fallbackName(key: string): string {
  const match = /^speaker[_-]?(\d+)$/i.exec(key);
  return match ? `Speaker ${match[1]}` : key;
}

/** Speaker key → color index. Used when drawing segments. */
export function colorIndexMap(views: SpeakerView[]): Record<string, number> {
  return Object.fromEntries(views.map((view) => [view.key, view.colorIndex]));
}

// ── speaker_map operations (apply to the whole speaker) ──

/** Renames a speaker. Applies to all of that speaker's utterances. */
export function renameSpeaker(
  speakerMap: Record<string, SpeakerMapEntry>,
  key: string,
  name: string,
): Record<string, SpeakerMapEntry> {
  const current = speakerMap[key] ?? { name: "", account_id: null };
  return { ...speakerMap, [key]: { ...current, name } };
}

/** Links a speaker to an account. Aligns the name too. */
export function assignSpeakerAccount(
  speakerMap: Record<string, SpeakerMapEntry>,
  key: string,
  account: { id: string; name?: string | null; email: string } | null,
): Record<string, SpeakerMapEntry> {
  const current = speakerMap[key] ?? { name: fallbackName(key), account_id: null };

  if (!account) {
    return { ...speakerMap, [key]: { ...current, account_id: null } };
  }

  return {
    ...speakerMap,
    [key]: { name: account.name || account.email, account_id: account.id },
  };
}

/** Adds a speaker. For manually adding someone STT missed. */
export function addSpeaker(
  speakerMap: Record<string, SpeakerMapEntry>,
  name: string,
): { speakerMap: Record<string, SpeakerMapEntry>; key: string } {
  // Find a number that does not collide with existing keys
  let n = Object.keys(speakerMap).length + 1;
  while (speakerMap[`speaker_${n}`]) n += 1;

  const key = `speaker_${n}`;
  return { speakerMap: { ...speakerMap, [key]: { name, account_id: null } }, key };
}

/**
 * Removes a speaker. Their utterances move to `moveTo`.
 *
 * Just dropping the utterances would lose transcript content, so a
 * destination is required.
 */
export function removeSpeaker(
  transcript: Transcript,
  speakerMap: Record<string, SpeakerMapEntry>,
  key: string,
  moveTo: string,
): { transcript: Transcript; speakerMap: Record<string, SpeakerMapEntry> } {
  const nextMap = { ...speakerMap };
  delete nextMap[key];

  const segments = transcript.segments.map((segment) =>
    segment.speaker === key ? { ...segment, speaker: moveTo } : segment,
  );

  return {
    transcript: { ...transcript, segments: mergeAdjacent(segments) },
    speakerMap: nextMap,
  };
}

// ── segment operations (one line only) ───────────────────

/** Changes one segment's speaker. For correcting STT misclassification. */
export function changeSegmentSpeaker(
  transcript: Transcript,
  index: number,
  speaker: string,
): Transcript {
  const segments = transcript.segments.map((segment, i) =>
    i === index ? { ...segment, speaker } : segment,
  );

  return { ...transcript, segments: mergeAdjacent(segments) };
}

/** Edits a segment's text. */
export function editSegmentText(
  transcript: Transcript,
  index: number,
  text: string,
): Transcript {
  const segments = transcript.segments.map((segment, i) =>
    i === index ? { ...segment, text } : segment,
  );

  return { ...transcript, segments };
}

/**
 * Splits a segment in two at the cursor position.
 *
 * For when two people's speech got mixed into one segment.
 * Timestamps split **proportionally by character count** — not exact, but
 * good enough to anchor playback.
 */
export function splitSegment(
  transcript: Transcript,
  index: number,
  charIndex: number,
): Transcript {
  const segment = transcript.segments[index];
  if (!segment) return transcript;

  const head = segment.text.slice(0, charIndex).trim();
  const tail = segment.text.slice(charIndex).trim();

  // Nothing to split if either side is empty
  if (!head || !tail) return transcript;

  const total = segment.text.length || 1;
  const span = segment.end_ms - segment.start_ms;
  const boundary = segment.start_ms + Math.round((span * charIndex) / total);

  const first: TranscriptSegment = { ...segment, text: head, end_ms: boundary };
  const second: TranscriptSegment = { ...segment, text: tail, start_ms: boundary };

  const segments = [
    ...transcript.segments.slice(0, index),
    first,
    second,
    ...transcript.segments.slice(index + 1),
  ];

  return { ...transcript, segments };
}

/** Reverts edits, back to the original saved right after transcription. */
export function restoreOriginal(transcript: Transcript): Transcript | null {
  if (!transcript.original_segments?.length) return null;
  return { ...transcript, segments: transcript.original_segments.map((s) => ({ ...s })) };
}

export function hasEdits(transcript: Transcript | null): boolean {
  if (!transcript?.original_segments?.length) return false;
  if (transcript.segments.length !== transcript.original_segments.length) return true;

  return transcript.segments.some((segment, i) => {
    const original = transcript.original_segments![i];
    return !original || original.text !== segment.text || original.speaker !== segment.speaker;
  });
}

/**
 * Merges consecutive segments by the same speaker.
 *
 * Speaker edits often leave the same person before and after; left alone,
 * one person's speech splinters into several bubbles and reads badly.
 */
export function mergeAdjacent(segments: TranscriptSegment[]): TranscriptSegment[] {
  return segments.reduce<TranscriptSegment[]>((acc, segment) => {
    const prev = acc[acc.length - 1];

    if (prev && prev.speaker === segment.speaker) {
      acc[acc.length - 1] = {
        ...prev,
        text: `${prev.text} ${segment.text}`.trim(),
        end_ms: segment.end_ms,
      };
      return acc;
    }

    acc.push({ ...segment });
    return acc;
  }, []);
}

// ── Display ──────────────────────────────────────────────

/** `mm:ss` or `h:mm:ss`. For segment timestamps. */
export function timeLabel(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

/** The segment at the current playback position. -1 if none. */
export function segmentAt(segments: TranscriptSegment[], ms: number): number {
  return segments.findIndex((segment) => ms >= segment.start_ms && ms < segment.end_ms);
}

/** Exports as Markdown. */
export function toMarkdown(
  title: string,
  transcript: Transcript | null,
  speakerMap: Record<string, SpeakerMapEntry>,
): string {
  const segments = transcript?.segments ?? [];
  const name = (key: string) => speakerMap[key]?.name || fallbackName(key);

  const lines = segments.map(
    (segment) => `**${name(segment.speaker)}** \`${timeLabel(segment.start_ms)}\`\n\n${segment.text}\n`,
  );

  return [`# ${title}`, "", ...lines].join("\n");
}
