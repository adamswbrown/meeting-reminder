import { tz } from "@date-fns/tz";
import {
  addDays,
  max,
  min,
  setHours,
  setMinutes,
  setSeconds,
  setMilliseconds,
  startOfDay,
} from "date-fns";
import { config } from "./config";
import type { FreeBusyEvent } from "./supabase";

export interface FreeSlot {
  start: Date;
  end: Date;
  /** Length in minutes — precomputed for filtering and rendering. */
  durationMinutes: number;
}

export interface DayOfSlots {
  /** Midnight at the start of this day in the owner's timezone. */
  dayStart: Date;
  slots: FreeSlot[];
}

interface Interval {
  start: Date;
  end: Date;
}

const ownerTZ = tz(config.timezone);

/**
 * Set a wall-clock time (in the owner's timezone) on a given day. Returns
 * a Date whose UTC value corresponds to that local moment, with DST handled
 * by @date-fns/tz.
 */
function atOwnerTime(
  day: Date,
  hours: number,
  minutes: number
): Date {
  let d = setHours(day, hours, { in: ownerTZ });
  d = setMinutes(d, minutes, { in: ownerTZ });
  d = setSeconds(d, 0, { in: ownerTZ });
  d = setMilliseconds(d, 0, { in: ownerTZ });
  return d;
}

function workingWindowFor(day: Date): Interval {
  return {
    start: atOwnerTime(day, config.workdayStartHour, 0),
    end: atOwnerTime(day, config.workdayEndHour, 0),
  };
}

function lunchFor(day: Date): Interval {
  return {
    start: atOwnerTime(day, config.lunchStartHour, config.lunchStartMinute),
    end: atOwnerTime(day, config.lunchEndHour, config.lunchEndMinute),
  };
}

/**
 * Subtract a set of busy intervals from a single window, returning the
 * remaining free fragments. Inputs can overlap and arrive unsorted.
 */
function subtractBusy(window: Interval, busy: Interval[]): Interval[] {
  const clamped = busy
    .map((b) => ({
      start: max([b.start, window.start]),
      end: min([b.end, window.end]),
    }))
    .filter((b) => b.start < b.end)
    .sort((a, b) => a.start.getTime() - b.start.getTime());

  // Merge overlapping busy intervals so we walk the timeline once.
  const merged: Interval[] = [];
  for (const b of clamped) {
    const last = merged[merged.length - 1];
    if (last && b.start <= last.end) {
      last.end = max([last.end, b.end]);
    } else {
      merged.push({ ...b });
    }
  }

  // Walk the window, emitting whatever's not covered.
  const free: Interval[] = [];
  let cursor = window.start;
  for (const b of merged) {
    if (b.start > cursor) {
      free.push({ start: cursor, end: b.start });
    }
    cursor = max([cursor, b.end]);
  }
  if (cursor < window.end) {
    free.push({ start: cursor, end: window.end });
  }
  return free;
}

/** Returns the local weekday number (0=Sun..6=Sat) in the owner's timezone. */
function weekdayNumber(d: Date): number {
  const short = new Intl.DateTimeFormat("en-US", {
    weekday: "short",
    timeZone: config.timezone,
  }).format(d);
  const map: Record<string, number> = {
    Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6,
  };
  return map[short] ?? -1;
}

/** Round a Date up to the next quarter-hour boundary. */
function roundUpToQuarterHour(d: Date): Date {
  const quarter = 15 * 60 * 1000;
  return new Date(Math.ceil(d.getTime() / quarter) * quarter);
}

/**
 * Given the raw Supabase events, compute free slots grouped by day for the
 * next N days in the owner's timezone. Today's slots are filtered to slots
 * starting after `now` so we don't suggest a slot that's already underway.
 */
export function computeAvailability(
  events: FreeBusyEvent[],
  now: Date = new Date()
): DayOfSlots[] {
  const busyIntervals: Interval[] = events.map((e) => ({
    start: new Date(e.start_utc),
    end: new Date(e.end_utc),
  }));

  const today = startOfDay(now, { in: ownerTZ });
  const days: DayOfSlots[] = [];

  for (let offset = 0; offset < config.lookAheadDays; offset++) {
    const day = addDays(today, offset, { in: ownerTZ });
    if (!config.workdays.includes(weekdayNumber(day))) continue;

    const window = workingWindowFor(day);
    // On today, clip the window so we don't show slots that are in the past.
    if (offset === 0 && now > window.start) {
      window.start = roundUpToQuarterHour(now);
      if (window.start >= window.end) continue;
    }

    // Only intervals that overlap this day's working window matter.
    const overlapping = busyIntervals.filter(
      (b) => b.end > window.start && b.start < window.end
    );
    const busyWithLunch = [...overlapping, lunchFor(day)];

    const free = subtractBusy(window, busyWithLunch)
      .map((slot) => ({
        start: slot.start,
        end: slot.end,
        durationMinutes:
          (slot.end.getTime() - slot.start.getTime()) / 60_000,
      }))
      .filter((slot) => slot.durationMinutes >= config.minSlotMinutes);

    if (free.length > 0) {
      days.push({ dayStart: day, slots: free });
    }
  }

  return days;
}
