import { tz } from "@date-fns/tz";
import { addDays, startOfDay } from "date-fns";
import {
  atOwnerTime,
  subtractBusy,
  weekdayNumber,
  type Interval,
} from "./availability";
import { config } from "./config";
import type { EventType, Weekday } from "./eventTypes";
import { rest, type FreeBusyEvent } from "./supabase";

/** A bookable slot, ISO strings so it survives the RSC→client boundary. */
export interface BookingSlot {
  startISO: string;
  endISO: string;
}

/** Times-only shape of a row from the `public_booked_slots` view. */
export interface BookedSlot {
  start_utc: string;
  end_utc: string;
}

/**
 * Fetch already-taken pending/confirmed booking slots from the
 * `public_booked_slots` view (start/end only — no booker PII is exposed to
 * anon). Mirrors `fetchFreeBusy`'s overlap window: any slot that hasn't
 * ended yet and starts before the look-ahead horizon. Used to carve booked
 * time out of the generated slot grid.
 */
export async function fetchBookedSlots(): Promise<BookedSlot[]> {
  const now = new Date();
  const horizon = new Date(now);
  horizon.setUTCDate(horizon.getUTCDate() + config.lookAheadDays);

  const params = new URLSearchParams({
    select: "start_utc,end_utc",
    end_utc: `gte.${now.toISOString()}`,
    start_utc: `lt.${horizon.toISOString()}`,
    order: "start_utc.asc",
  });
  const query = params.toString().replace(/%2C/g, ",");
  return rest<BookedSlot[]>(`public_booked_slots?${query}`);
}

export interface GenerateSlotsArgs {
  eventType: EventType;
  /** Owner busy intervals (e.g. from `fetchFreeBusy`). */
  freeBusy: FreeBusyEvent[];
  /** Already-taken pending/confirmed bookings. */
  bookedSlots: BookedSlot[];
  now: Date;
  lookAheadDays: number;
}

const ownerTZ = tz(config.timezone);

// 0=Sun..6=Sat -> weekday key used in EventType.hours.
const WEEKDAY_KEY: Record<number, Weekday> = {
  0: "sun",
  1: "mon",
  2: "tue",
  3: "wed",
  4: "thu",
  5: "fri",
  6: "sat",
};

/** Parse a "HH:mm" string anchored to `day` in the owner's timezone. */
function timeOnDay(day: Date, hhmm: string): Date {
  const [h, m] = hhmm.split(":").map((n) => parseInt(n, 10));
  return atOwnerTime(day, h, m);
}

/**
 * Generate available slots for an event type across the look-ahead window.
 *
 * Reuses the interval maths from `lib/availability.ts`: `subtractBusy` carves
 * busy/booked time out of each weekday's configured hours window, and
 * `atOwnerTime`/`weekdayNumber` keep everything anchored to Europe/London.
 * The discretiser here is bespoke (step = duration + bufferAfter rather than
 * back-to-back), which is why it doesn't call `discretiseWindow`.
 */
export function generateSlots({
  eventType,
  freeBusy,
  bookedSlots,
  now,
  lookAheadDays,
}: GenerateSlotsArgs): BookingSlot[] {
  const durationMs = eventType.durationMin * 60 * 1000;
  const stepMs = (eventType.durationMin + eventType.bufferAfter) * 60 * 1000;
  const bufferBeforeMs = eventType.bufferBefore * 60 * 1000;
  const noticeCutoff = new Date(now.getTime() + eventType.minNoticeMin * 60 * 1000);

  // Busy intervals: owner free/busy padded earlier by bufferBefore, plus
  // already-booked slots (no padding — they're exact).
  const busyIntervals: Interval[] = [
    ...freeBusy.map((e) => ({
      start: new Date(new Date(e.start_utc).getTime() - bufferBeforeMs),
      end: new Date(e.end_utc),
    })),
    ...bookedSlots.map((b) => ({
      start: new Date(b.start_utc),
      end: new Date(b.end_utc),
    })),
  ];

  const today = startOfDay(now, { in: ownerTZ });
  const out: BookingSlot[] = [];

  for (let offset = 0; offset < lookAheadDays; offset++) {
    const day = addDays(today, offset, { in: ownerTZ });
    const key = WEEKDAY_KEY[weekdayNumber(day)];
    const ranges = eventType.hours[key] ?? [];
    if (ranges.length === 0) continue;

    let perDay = 0;

    for (const [startStr, endStr] of ranges) {
      const window: Interval = {
        start: timeOnDay(day, startStr),
        end: timeOnDay(day, endStr),
      };

      const overlapping = busyIntervals.filter(
        (b) => b.end > window.start && b.start < window.end
      );
      // The free fragments tell us instantly whether a candidate slot is clear:
      // a slot is bookable iff it sits wholly inside one free fragment.
      const free = subtractBusy(window, overlapping);

      // Walk a fixed grid anchored to the range start (step = duration +
      // bufferAfter) so buffer spacing stays consistent regardless of where
      // busy blocks fall.
      let cursor = window.start.getTime();
      while (cursor + durationMs <= window.end.getTime()) {
        const start = new Date(cursor);
        const end = cursor + durationMs;

        if (start >= noticeCutoff) {
          const clear = free.some(
            (f) => f.start.getTime() <= cursor && f.end.getTime() >= end
          );
          if (clear) {
            if (eventType.maxPerDay != null && perDay >= eventType.maxPerDay) {
              break;
            }
            out.push({
              startISO: start.toISOString(),
              endISO: new Date(end).toISOString(),
            });
            perDay++;
          }
        }
        cursor += stepMs;
      }
      if (eventType.maxPerDay != null && perDay >= eventType.maxPerDay) break;
    }
  }

  return out;
}
