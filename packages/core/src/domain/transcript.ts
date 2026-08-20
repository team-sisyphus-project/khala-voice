/**
 * 전사 · 화자 조작.
 *
 * **출처: sisyphus** `assets/webapp/meeting-recorder.js` 2416~3470, 5362~5960
 * — 로직만 떼어내 UI 의존을 없앴다.
 *
 * ## 화자는 2계층이다
 *
 *     transcript.segments[i].speaker  =  "speaker_1"          ← STT 원본, 세그먼트별
 *     speaker_map["speaker_1"]        =  { name, account_id } ← 사람 매핑, 화자별
 *
 * 이 둘을 합치고 싶어지지만 **서로 다른 조작**이다.
 *
 * - 화자 칩을 바꾸면 → `speaker_map` → 그 화자의 **모든** 발언에 반영
 * - 세그먼트 아바타를 바꾸면 → `segments[i].speaker` → **그 한 줄만**
 *
 * 두 번째는 STT 가 화자를 잘못 나눴을 때 쓴다. 합치면 이걸 못 한다.
 */

import type { SpeakerMapEntry, Transcript, TranscriptSegment } from "../api/types";

export interface SpeakerView {
  /** `speaker_1` 같은 원본 키 */
  key: string;
  /** 화면에 보일 이름 */
  name: string;
  accountId: string | null;
  /** 이 화자의 발화 수 */
  segmentCount: number;
  /** 이 화자가 말한 총 길이(ms) */
  totalMs: number;
  /** 팔레트 인덱스 (1~10). 등장 순서로 고정된다 */
  colorIndex: number;
}

export const SPEAKER_COLOR_COUNT = 10;

/**
 * 화면에 뿌릴 화자 목록.
 *
 * **등장 순서로 색을 고정한다.** 이름을 바꿔도 색이 유지돼야
 * 사용자가 "아까 파란 사람"으로 기억한 걸 잃지 않는다.
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

  // 발화가 하나도 없는 화자도 맵에 있으면 보여준다 (사용자가 추가한 경우)
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
  return match ? `화자 ${match[1]}` : key;
}

/** 화자 키 → 색 인덱스. 세그먼트를 그릴 때 쓴다. */
export function colorIndexMap(views: SpeakerView[]): Record<string, number> {
  return Object.fromEntries(views.map((view) => [view.key, view.colorIndex]));
}

// ── speaker_map 조작 (화자 전체에 반영) ───────────────────

/** 화자 이름을 바꾼다. 그 화자의 모든 발언에 반영된다. */
export function renameSpeaker(
  speakerMap: Record<string, SpeakerMapEntry>,
  key: string,
  name: string,
): Record<string, SpeakerMapEntry> {
  const current = speakerMap[key] ?? { name: "", account_id: null };
  return { ...speakerMap, [key]: { ...current, name } };
}

/** 화자를 계정에 연결한다. 이름도 함께 맞춘다. */
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

/** 화자를 추가한다. STT 가 놓친 사람을 수동으로 넣을 때. */
export function addSpeaker(
  speakerMap: Record<string, SpeakerMapEntry>,
  name: string,
): { speakerMap: Record<string, SpeakerMapEntry>; key: string } {
  // 기존 키와 겹치지 않는 번호를 찾는다
  let n = Object.keys(speakerMap).length + 1;
  while (speakerMap[`speaker_${n}`]) n += 1;

  const key = `speaker_${n}`;
  return { speakerMap: { ...speakerMap, [key]: { name, account_id: null } }, key };
}

/**
 * 화자를 지운다. 그 화자의 발언은 `moveTo` 로 옮긴다.
 *
 * 발언을 그냥 버리면 전사가 사라진다. 반드시 옮길 곳을 받는다.
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

// ── segments 조작 (한 줄만 반영) ──────────────────────────

/** 한 세그먼트의 화자를 바꾼다. STT 오분류 교정용. */
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

/** 세그먼트 본문을 고친다. */
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
 * 세그먼트를 커서 위치에서 둘로 나눈다.
 *
 * 한 세그먼트에 두 사람의 말이 섞였을 때 쓴다.
 * 시각은 **글자 수 비율로 나눈다** — 정확하진 않지만 재생 위치를 잡기엔 충분하다.
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

  // 한쪽이 비면 나눌 것이 없다
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

/** 편집을 되돌린다. 전사 직후 저장해 둔 원본으로. */
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
 * 같은 화자가 이어지면 하나로 합친다.
 *
 * 화자를 바꾸다 보면 앞뒤가 같은 사람이 되는데, 그대로 두면
 * 같은 사람 말풍선이 여러 개로 쪼개져 읽기 나빠진다.
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

// ── 표시 ──────────────────────────────────────────────────

/** `mm:ss` 또는 `h:mm:ss`. 세그먼트 시각 표시용. */
export function timeLabel(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

/** 현재 재생 위치에 해당하는 세그먼트. 없으면 -1. */
export function segmentAt(segments: TranscriptSegment[], ms: number): number {
  return segments.findIndex((segment) => ms >= segment.start_ms && ms < segment.end_ms);
}

/** 마크다운으로 내보낸다. */
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
