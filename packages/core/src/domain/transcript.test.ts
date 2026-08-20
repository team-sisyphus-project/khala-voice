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
    seg("speaker_1", "안녕하세요", 0, 2000),
    seg("speaker_2", "네 반갑습니다", 2000, 4000),
    seg("speaker_1", "시작할까요", 4000, 6000),
  ];

  return { segments, original_segments: segments.map((s) => ({ ...s })) };
}

const MAP: Record<string, SpeakerMapEntry> = {
  speaker_1: { name: "김철수", account_id: "acct_1" },
  speaker_2: { name: "화자 2", account_id: null },
};

describe("speakerViews", () => {
  it("등장 순서로 색을 고정한다", () => {
    const views = speakerViews(fixture(), MAP);
    deepEqual(
      views.map((v) => [v.key, v.colorIndex]),
      [
        ["speaker_1", 1],
        ["speaker_2", 2],
      ],
    );
  });

  it("이름을 바꿔도 색이 유지된다", () => {
    const before = colorIndexMap(speakerViews(fixture(), MAP));
    const after = colorIndexMap(
      speakerViews(fixture(), renameSpeaker(MAP, "speaker_1", "박영수")),
    );
    deepEqual(before, after);
  });

  it("발화 수와 길이를 센다", () => {
    const views = speakerViews(fixture(), MAP);
    equal(views[0]!.segmentCount, 2);
    equal(views[0]!.totalMs, 4000);
    equal(views[1]!.segmentCount, 1);
  });

  it("발화가 없는 화자도 맵에 있으면 보여준다", () => {
    const map = { ...MAP, speaker_9: { name: "늦게 온 사람", account_id: null } };
    const views = speakerViews(fixture(), map);
    equal(views.length, 3);
    equal(views[2]!.segmentCount, 0);
  });

  it("맵에 없는 화자는 화자 N 으로 부른다", () => {
    const views = speakerViews(fixture(), {});
    deepEqual(views.map((v) => v.name), ["화자 1", "화자 2"]);
  });

  it("전사가 없어도 터지지 않는다", () => {
    deepEqual(speakerViews(null, {}), []);
  });
});

describe("speaker_map 조작", () => {
  it("계정을 연결하면 이름도 맞춘다", () => {
    const next = assignSpeakerAccount(MAP, "speaker_2", {
      id: "acct_2",
      name: "이영희",
      email: "lee@test.com",
    });
    deepEqual(next["speaker_2"], { name: "이영희", account_id: "acct_2" });
  });

  it("이름이 없는 계정은 이메일을 쓴다", () => {
    const next = assignSpeakerAccount(MAP, "speaker_2", {
      id: "acct_2",
      name: null,
      email: "lee@test.com",
    });
    equal(next["speaker_2"]!.name, "lee@test.com");
  });

  it("연결을 끊어도 이름은 남는다", () => {
    const next = assignSpeakerAccount(MAP, "speaker_1", null);
    deepEqual(next["speaker_1"], { name: "김철수", account_id: null });
  });

  it("추가한 화자는 기존 키와 겹치지 않는다", () => {
    const map = { speaker_1: MAP["speaker_1"]!, speaker_3: MAP["speaker_2"]! };
    const { key, speakerMap } = addSpeaker(map, "새 사람");
    ok(!(key in map));
    equal(speakerMap[key]!.name, "새 사람");
  });

  it("화자를 지우면 발언은 옮겨간다", () => {
    const { transcript, speakerMap } = removeSpeaker(
      fixture(),
      MAP,
      "speaker_2",
      "speaker_1",
    );
    ok(!("speaker_2" in speakerMap));
    // 셋 다 speaker_1 이 되어 하나로 합쳐진다
    equal(transcript.segments.length, 1);
    equal(transcript.segments[0]!.text, "안녕하세요 네 반갑습니다 시작할까요");
    equal(transcript.segments[0]!.end_ms, 6000);
  });
});

describe("세그먼트 조작", () => {
  it("화자를 바꾸면 앞뒤가 합쳐진다", () => {
    const next = changeSegmentSpeaker(fixture(), 1, "speaker_1");
    equal(next.segments.length, 1);
    equal(next.segments[0]!.speaker, "speaker_1");
  });

  it("본문 수정은 합치지 않는다", () => {
    const next = editSegmentText(fixture(), 1, "고침");
    equal(next.segments.length, 3);
    equal(next.segments[1]!.text, "고침");
  });

  it("나누면 시각이 글자 수 비율로 갈린다", () => {
    const t: Transcript = { segments: [seg("speaker_1", "0123456789", 0, 1000)] };
    const next = splitSegment(t, 0, 5);
    equal(next.segments.length, 2);
    equal(next.segments[0]!.text, "01234");
    equal(next.segments[0]!.end_ms, 500);
    equal(next.segments[1]!.start_ms, 500);
    equal(next.segments[1]!.end_ms, 1000);
  });

  it("한쪽이 비면 나누지 않는다", () => {
    const t = fixture();
    equal(splitSegment(t, 0, 0).segments.length, 3);
    equal(splitSegment(t, 0, 999).segments.length, 3);
  });

  it("없는 세그먼트를 나누라 하면 그대로 둔다", () => {
    const t = fixture();
    equal(splitSegment(t, 99, 2), t);
  });
});

describe("원본 복원", () => {
  it("편집 여부를 판별한다", () => {
    const t = fixture();
    equal(hasEdits(t), false);
    equal(hasEdits(editSegmentText(t, 0, "다른 말")), true);
    equal(hasEdits(changeSegmentSpeaker(t, 1, "speaker_1")), true);
  });

  it("원본이 없으면 편집으로 보지 않는다", () => {
    equal(hasEdits({ segments: [seg("speaker_1", "말", 0, 1)] }), false);
    equal(hasEdits(null), false);
  });

  it("되돌리면 원본과 같아진다", () => {
    const edited = editSegmentText(fixture(), 0, "고친 말");
    const restored = restoreOriginal(edited);
    ok(restored);
    deepEqual(restored.segments, fixture().segments);
    equal(hasEdits(restored), false);
  });

  it("원본이 없으면 null 을 준다", () => {
    equal(restoreOriginal({ segments: [] }), null);
  });
});

describe("mergeAdjacent", () => {
  it("같은 화자만 합친다", () => {
    const merged = mergeAdjacent([
      seg("speaker_1", "가", 0, 1000),
      seg("speaker_1", "나", 1000, 2000),
      seg("speaker_2", "다", 2000, 3000),
    ]);
    deepEqual(merged.map((s) => s.text), ["가 나", "다"]);
    equal(merged[0]!.end_ms, 2000);
  });

  it("원본 배열을 건드리지 않는다", () => {
    const input = [seg("speaker_1", "가", 0, 1000), seg("speaker_1", "나", 1000, 2000)];
    mergeAdjacent(input);
    equal(input.length, 2);
    equal(input[0]!.text, "가");
  });
});

describe("표시", () => {
  it("한 시간 미만은 mm:ss", () => {
    equal(timeLabel(0), "00:00");
    equal(timeLabel(65_000), "01:05");
    equal(timeLabel(-5), "00:00");
  });

  it("한 시간부터는 h:mm:ss", () => {
    equal(timeLabel(3_725_000), "1:02:05");
  });

  it("재생 위치의 세그먼트를 찾는다", () => {
    const { segments } = fixture();
    equal(segmentAt(segments, 0), 0);
    equal(segmentAt(segments, 1999), 0);
    equal(segmentAt(segments, 2000), 1);
    equal(segmentAt(segments, 99_000), -1);
  });

  it("마크다운으로 내보낸다", () => {
    const md = toMarkdown("회의", fixture(), MAP);
    ok(md.startsWith("# 회의"));
    ok(md.includes("**김철수** `00:00`"));
    ok(md.includes("**화자 2** `00:02`"));
  });
});
