import { describe, expect, it } from "vitest";
import { generateSlots } from "./bookingSlots";
import type { EventType } from "./eventTypes";
import type { FreeBusyEvent } from "./supabase";

// A Monday in BST (Europe/London = UTC+1). 2026-06-22 is a Monday.
// 09:00 London on that day == 08:00 UTC.
function et(overrides: Partial<EventType> = {}): EventType {
  return {
    id: "et-1",
    slug: "intro-30",
    title: "Intro",
    description: null,
    durationMin: 30,
    bufferBefore: 0,
    bufferAfter: 10,
    minNoticeMin: 0,
    maxPerDay: null,
    hours: {
      mon: [["09:00", "12:00"]],
      tue: [],
      wed: [],
      thu: [],
      fri: [],
      sat: [],
      sun: [],
    },
    questions: [],
    active: true,
    ...overrides,
  };
}

function busy(startISO: string, endISO: string): FreeBusyEvent {
  return {
    event_id: "b",
    start_utc: startISO,
    end_utc: endISO,
    is_all_day: false,
    is_tentative: false,
    is_ooo: false,
    status: "confirmed",
  };
}

// Fix "now" well before the Monday so min-notice tests are isolated.
const NOW = new Date("2026-06-22T00:00:00Z");

describe("generateSlots", () => {
  it("rule 1+2: slots fall inside hours, spaced by duration+bufferAfter, length=duration", () => {
    const slots = generateSlots({
      eventType: et(),
      freeBusy: [],
      bookedSlots: [],
      now: NOW,
      lookAheadDays: 2,
    });
    // 09:00–12:00 London, 30+10 spacing => 09:00, 09:40, 10:20, 11:00, 11:40.
    // 11:40 + 30 = 12:10 > 12:00 so it's dropped. => 09:00,09:40,10:20,11:00.
    expect(slots.map((s) => s.startISO)).toEqual([
      "2026-06-22T08:00:00.000Z",
      "2026-06-22T08:40:00.000Z",
      "2026-06-22T09:20:00.000Z",
      "2026-06-22T10:00:00.000Z",
    ]);
    // length 30 min
    for (const s of slots) {
      expect(new Date(s.endISO).getTime() - new Date(s.startISO).getTime()).toBe(
        30 * 60 * 1000
      );
    }
  });

  it("rule 3: a slot overlapping a freeBusy interval (padded by bufferBefore) is excluded", () => {
    // bufferBefore 15: a busy block 09:50–10:10 London padded earlier to 09:35.
    // 09:35–10:10 kills the 09:00 (ends 09:30 — no), 09:40 (overlaps), 10:20? starts after 10:10 ok.
    const slots = generateSlots({
      eventType: et({ bufferBefore: 15 }),
      freeBusy: [busy("2026-06-22T08:50:00.000Z", "2026-06-22T09:10:00.000Z")],
      bookedSlots: [],
      now: NOW,
      lookAheadDays: 2,
    });
    const starts = slots.map((s) => s.startISO);
    expect(starts).toContain("2026-06-22T08:00:00.000Z"); // 09:00, ends 09:30 < 09:35 pad start
    expect(starts).not.toContain("2026-06-22T08:40:00.000Z"); // 09:40 overlaps padded busy
    expect(starts).toContain("2026-06-22T09:20:00.000Z"); // 10:20 after busy
  });

  it("rule 4: a slot overlapping a bookedSlots interval is excluded", () => {
    const slots = generateSlots({
      eventType: et(),
      freeBusy: [],
      bookedSlots: [
        { start_utc: "2026-06-22T08:40:00.000Z", end_utc: "2026-06-22T09:10:00.000Z" },
      ],
      now: NOW,
      lookAheadDays: 2,
    });
    const starts = slots.map((s) => s.startISO);
    expect(starts).not.toContain("2026-06-22T08:40:00.000Z");
    expect(starts).toContain("2026-06-22T08:00:00.000Z");
  });

  it("rule 5: slots starting before now+minNoticeMin are excluded", () => {
    // now = Monday 09:10 London (08:10 UTC), minNotice 120 => cutoff 11:10 London.
    const slots = generateSlots({
      eventType: et({ minNoticeMin: 120 }),
      freeBusy: [],
      bookedSlots: [],
      now: new Date("2026-06-22T08:10:00.000Z"),
      lookAheadDays: 2,
    });
    const starts = slots.map((s) => s.startISO);
    // cutoff 10:10 UTC (11:10 London). Only 11:40 London? no, 11:40 dropped by length.
    // remaining valid starts before cutoff removed: all of 09:00,09:40,10:20,11:00 are < 10:10 UTC
    // 10:20 UTC? wait recompute: starts are 08:00,08:40,09:20,10:00 UTC. cutoff 10:10 UTC.
    // all are before cutoff => empty.
    expect(starts).toEqual([]);
  });

  it("rule 6: maxPerDay caps slots per day", () => {
    const slots = generateSlots({
      eventType: et({ maxPerDay: 2 }),
      freeBusy: [],
      bookedSlots: [],
      now: NOW,
      lookAheadDays: 2,
    });
    expect(slots.length).toBe(2);
    expect(slots.map((s) => s.startISO)).toEqual([
      "2026-06-22T08:00:00.000Z",
      "2026-06-22T08:40:00.000Z",
    ]);
  });

  it("respects multiple ranges per weekday and only configured weekdays", () => {
    const slots = generateSlots({
      eventType: et({
        durationMin: 60,
        bufferAfter: 0,
        hours: {
          mon: [],
          tue: [["10:00", "12:00"]],
          wed: [],
          thu: [["10:00", "12:00"]],
          fri: [],
          sat: [],
          sun: [],
        },
      }),
      freeBusy: [],
      bookedSlots: [],
      now: NOW,
      lookAheadDays: 7,
    });
    // Tue 2026-06-23 and Thu 2026-06-25, 10:00 & 11:00 London each (09:00,10:00 UTC).
    expect(slots.map((s) => s.startISO)).toEqual([
      "2026-06-23T09:00:00.000Z",
      "2026-06-23T10:00:00.000Z",
      "2026-06-25T09:00:00.000Z",
      "2026-06-25T10:00:00.000Z",
    ]);
  });
});
