import { deepEqual, equal, ok } from "node:assert/strict";
import { describe, it } from "node:test";
import {
  addSpeaker,
  assignSpeakerAccount,
  changeSegmentSpeaker,
  colorIndexMap,
  editSegmentText,
  hasEdits,
  mergeAdjacent,
  removeSpeaker,
  renameSpeaker,
  restoreOriginal,
  segmentAt,
  speakerViews,
  splitSegment,
  timeLabel,
  toMarkdown,
} from "./transcript.ts";
import type { SpeakerMapEntry, Transcript, TranscriptSegment } from "../api/types.ts";

function seg(
  speaker: string,
  text: string,
  start_ms: number,
  end_ms: number,
): TranscriptSegment {
  return { speaker, text, start_ms, end_ms, confidence: 0.9 };
}

function fixture(): Transcript {
  const segments = [
    seg("speaker_1", "Hello everyone", 0, 2000),
    seg("speaker_2", "Hi, good to see you", 2000, 4000),
    seg("speaker_1", "Shall we start", 4000, 6000),
  ];

  return { segments, original_segments: segments.map((s) => ({ ...s })) };
}

const MAP: Record<string, SpeakerMapEntry> = {
  speaker_1: { name: "Alice Kim", account_id: "acct_1" },
  speaker_2: { name: "Speaker 2", account_id: null },
};

describe("speakerViews", () => {
  it("fixes colors by order of appearance", () => {
    const views = speakerViews(fixture(), MAP);
    deepEqual(
      views.map((v) => [v.key, v.colorIndex]),
      [
        ["speaker_1", 1],
        ["speaker_2", 2],
      ],
    );
  });

  it("keeps colors across renames", () => {
    const before = colorIndexMap(speakerViews(fixture(), MAP));
    const after = colorIndexMap(
      speakerViews(fixture(), renameSpeaker(MAP, "speaker_1", "Bob Park")),
    );
    deepEqual(before, after);
  });

  it("counts utterances and duration", () => {
    const views = speakerViews(fixture(), MAP);
    equal(views[0]!.segmentCount, 2);
    equal(views[0]!.totalMs, 4000);
    equal(views[1]!.segmentCount, 1);
  });

  it("shows zero-utterance speakers that are in the map", () => {
    const map = { ...MAP, speaker_9: { name: "Latecomer", account_id: null } };
    const views = speakerViews(fixture(), map);
    equal(views.length, 3);
    equal(views[2]!.segmentCount, 0);
  });

  it("calls unmapped speakers Speaker N", () => {
    const views = speakerViews(fixture(), {});
    deepEqual(views.map((v) => v.name), ["Speaker 1", "Speaker 2"]);
  });

  it("does not crash without a transcript", () => {
    deepEqual(speakerViews(null, {}), []);
  });
});

describe("speaker_map operations", () => {
  it("linking an account aligns the name", () => {
    const next = assignSpeakerAccount(MAP, "speaker_2", {
      id: "acct_2",
      name: "Grace Lee",
      email: "lee@test.com",
    });
    deepEqual(next["speaker_2"], { name: "Grace Lee", account_id: "acct_2" });
  });

  it("uses the email for accounts without a name", () => {
    const next = assignSpeakerAccount(MAP, "speaker_2", {
      id: "acct_2",
      name: null,
      email: "lee@test.com",
    });
    equal(next["speaker_2"]!.name, "lee@test.com");
  });

  it("unlinking keeps the name", () => {
    const next = assignSpeakerAccount(MAP, "speaker_1", null);
    deepEqual(next["speaker_1"], { name: "Alice Kim", account_id: null });
  });

  it("added speakers never collide with existing keys", () => {
    const map = { speaker_1: MAP["speaker_1"]!, speaker_3: MAP["speaker_2"]! };
    const { key, speakerMap } = addSpeaker(map, "New person");
    ok(!(key in map));
    equal(speakerMap[key]!.name, "New person");
  });

  it("removing a speaker moves their utterances", () => {
    const { transcript, speakerMap } = removeSpeaker(
      fixture(),
      MAP,
      "speaker_2",
      "speaker_1",
    );
    ok(!("speaker_2" in speakerMap));
    // All three become speaker_1 and merge into one
    equal(transcript.segments.length, 1);
    equal(transcript.segments[0]!.text, "Hello everyone Hi, good to see you Shall we start");
    equal(transcript.segments[0]!.end_ms, 6000);
  });
});

describe("segment operations", () => {
  it("changing the speaker merges neighbors", () => {
    const next = changeSegmentSpeaker(fixture(), 1, "speaker_1");
    equal(next.segments.length, 1);
    equal(next.segments[0]!.speaker, "speaker_1");
  });

  it("text edits do not merge", () => {
    const next = editSegmentText(fixture(), 1, "fixed");
    equal(next.segments.length, 3);
    equal(next.segments[1]!.text, "fixed");
  });

  it("splitting divides timestamps by character ratio", () => {
    const t: Transcript = { segments: [seg("speaker_1", "0123456789", 0, 1000)] };
    const next = splitSegment(t, 0, 5);
    equal(next.segments.length, 2);
    equal(next.segments[0]!.text, "01234");
    equal(next.segments[0]!.end_ms, 500);
    equal(next.segments[1]!.start_ms, 500);
    equal(next.segments[1]!.end_ms, 1000);
  });

  it("does not split when either side is empty", () => {
    const t = fixture();
    equal(splitSegment(t, 0, 0).segments.length, 3);
    equal(splitSegment(t, 0, 999).segments.length, 3);
  });

  it("leaves the transcript alone when splitting a missing segment", () => {
    const t = fixture();
    equal(splitSegment(t, 99, 2), t);
  });
});

describe("original restore", () => {
  it("detects whether there are edits", () => {
    const t = fixture();
    equal(hasEdits(t), false);
    equal(hasEdits(editSegmentText(t, 0, "different words")), true);
    equal(hasEdits(changeSegmentSpeaker(t, 1, "speaker_1")), true);
  });

  it("no original means no edits", () => {
    equal(hasEdits({ segments: [seg("speaker_1", "words", 0, 1)] }), false);
    equal(hasEdits(null), false);
  });

  it("restoring matches the original", () => {
    const edited = editSegmentText(fixture(), 0, "edited words");
    const restored = restoreOriginal(edited);
    ok(restored);
    deepEqual(restored.segments, fixture().segments);
    equal(hasEdits(restored), false);
  });

  it("returns null without an original", () => {
    equal(restoreOriginal({ segments: [] }), null);
  });
});

describe("mergeAdjacent", () => {
  it("merges only the same speaker", () => {
    const merged = mergeAdjacent([
      seg("speaker_1", "one", 0, 1000),
      seg("speaker_1", "two", 1000, 2000),
      seg("speaker_2", "three", 2000, 3000),
    ]);
    deepEqual(merged.map((s) => s.text), ["one two", "three"]);
    equal(merged[0]!.end_ms, 2000);
  });

  it("does not mutate the input array", () => {
    const input = [seg("speaker_1", "one", 0, 1000), seg("speaker_1", "two", 1000, 2000)];
    mergeAdjacent(input);
    equal(input.length, 2);
    equal(input[0]!.text, "one");
  });
});

describe("display", () => {
  it("under an hour is mm:ss", () => {
    equal(timeLabel(0), "00:00");
    equal(timeLabel(65_000), "01:05");
    equal(timeLabel(-5), "00:00");
  });

  it("from an hour up it is h:mm:ss", () => {
    equal(timeLabel(3_725_000), "1:02:05");
  });

  it("finds the segment at the playback position", () => {
    const { segments } = fixture();
    equal(segmentAt(segments, 0), 0);
    equal(segmentAt(segments, 1999), 0);
    equal(segmentAt(segments, 2000), 1);
    equal(segmentAt(segments, 99_000), -1);
  });

  it("exports as Markdown", () => {
    const md = toMarkdown("Meeting", fixture(), MAP);
    ok(md.startsWith("# Meeting"));
    ok(md.includes("**Alice Kim** `00:00`"));
    ok(md.includes("**Speaker 2** `00:02`"));
  });
});
