import { describe, expect, it } from "vitest";
import { parseEventType, type EventTypeRow } from "./eventTypes";

const introRow: EventTypeRow = {
  id: "11111111-1111-1111-1111-111111111111",
  slug: "intro-30",
  title: "Intro call",
  description: "A quick intro chat.",
  duration_min: 30,
  buffer_before: 0,
  buffer_after: 10,
  min_notice_min: 120,
  max_per_day: null,
  hours: {
    mon: [["09:00", "12:00"], ["14:00", "17:00"]],
    tue: [["09:00", "17:00"]],
    wed: [["09:00", "17:00"]],
    thu: [["09:00", "17:00"]],
    fri: [["09:00", "17:00"]],
  },
  questions: [{ id: "topic", label: "What's it about?", required: true }],
  active: true,
};

describe("parseEventType", () => {
  it("maps duration, buffers and min notice to camelCase", () => {
    const et = parseEventType(introRow);
    expect(et.id).toBe("11111111-1111-1111-1111-111111111111");
    expect(et.slug).toBe("intro-30");
    expect(et.title).toBe("Intro call");
    expect(et.description).toBe("A quick intro chat.");
    expect(et.durationMin).toBe(30);
    expect(et.bufferBefore).toBe(0);
    expect(et.bufferAfter).toBe(10);
    expect(et.minNoticeMin).toBe(120);
    expect(et.active).toBe(true);
  });

  it("maps max_per_day null through as null", () => {
    expect(parseEventType(introRow).maxPerDay).toBeNull();
    expect(parseEventType({ ...introRow, max_per_day: 3 }).maxPerDay).toBe(3);
  });

  it("parses hours.mon into the expected ranges", () => {
    const et = parseEventType(introRow);
    expect(et.hours.mon).toEqual([
      ["09:00", "12:00"],
      ["14:00", "17:00"],
    ]);
    expect(et.hours.tue).toEqual([["09:00", "17:00"]]);
  });

  it("defaults missing weekdays to empty arrays", () => {
    const et = parseEventType(introRow);
    expect(et.hours.sat).toEqual([]);
    expect(et.hours.sun).toEqual([]);
  });

  it("carries questions through", () => {
    const et = parseEventType(introRow);
    expect(et.questions).toEqual([
      { id: "topic", label: "What's it about?", required: true },
    ]);
  });

  it("treats a null description as null", () => {
    const et = parseEventType({ ...introRow, description: null });
    expect(et.description).toBeNull();
  });
});
