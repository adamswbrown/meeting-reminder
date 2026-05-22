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

/**
 * A fixed-duration bookable slot. Serialised to ISO strings so it can cross
 * the RSC -> client component boundary without needing custom serialisation.
 */
export interface DiscreteSlot {
  startISO: string;
  endISO: string;
}

export interface DayOfDiscreteSlots {
  /** Midnight in the owner's timezone, ISO 8601 UTC. */
  dayStartISO: string;
  slots: DiscreteSlot[];
}

interface Interval {
  start: Date;
  end: Date;
}

const ownerTZ = tz(config.timezone);

function atOwnerTime(day: Date, hours: number, minutes: number): Date {
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
 * Subtract busy intervals from a window, returning the free fragments.
 * Inputs can overlap and arrive unsorted.
 */
function subtractBusy(window: Interval, busy: Interval[]): Interval[] {
  const clamped = busy
    .map((b) => ({
      start: max([b.start, window.start]),
      end: min([b.end, window.end]),
    }))
    .filter((b) => b.start < b.end)
    .sort((a, b) => a.start.getTime() - b.start.getTime());

  const merged: Interval[] = [];
  for (const b of clamped) {
    const last = merged[merged.length - 1];
    if (last && b.start <= last.end) {
      last.end = max([last.end, b.end]);
    } else {
      merged.push({ ...b });
    }
  }

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

/** Round a Date up to the next multiple of `stepMinutes`. */
function roundUp(d: Date, stepMinutes: number): Date {
  const stepMs = stepMinutes * 60 * 1000;
  return new Date(Math.ceil(d.getTime() / stepMs) * stepMs);
}

/**
 * Subdivide a contiguous free window into fixed-length, non-overlapping
 * slots. Each slot start is aligned to the configured alignment in UTC,
 * which yields clean quarter-hour starts in any timezone (since 15 min
 * divides 60 evenly regardless of UTC offset).
 */
function discretiseWindow(
  window: Interval,
  durationMinutes: number
): DiscreteSlot[] {
  const slots: DiscreteSlot[] = [];
  const durationMs = durationMinutes * 60 * 1000;

  let cursor = roundUp(window.start, config.slotAlignmentMinutes);
  while (cursor.getTime() + durationMs <= window.end.getTime()) {
    const slotEnd = new Date(cursor.getTime() + durationMs);
    slots.push({
      startISO: cursor.toISOString(),
      endISO: slotEnd.toISOString(),
    });
    cursor = new Date(cursor.getTime() + durationMs);
  }
  return slots;
}

/**
 * Compute discretised bookable slots for a given meeting duration. Run
 * once per duration the visitor can pick from; results are passed to the
 * client component which switches between them on toggle.
 */
export function computeAvailabilityForDuration(
  events: FreeBusyEvent[],
  durationMinutes: number,
  now: Date = new Date()
): DayOfDiscreteSlots[] {
  const busyIntervals: Interval[] = events.map((e) => ({
    start: new Date(e.start_utc),
    end: new Date(e.end_utc),
  }));

  const today = startOfDay(now, { in: ownerTZ });
  const days: DayOfDiscreteSlots[] = [];

  for (let offset = 0; offset < config.lookAheadDays; offset++) {
    const day = addDays(today, offset, { in: ownerTZ });
    if (!config.workdays.includes(weekdayNumber(day))) continue;

    const window = workingWindowFor(day);
    if (offset === 0 && now > window.start) {
      window.start = roundUp(now, config.slotAlignmentMinutes);
      if (window.start >= window.end) continue;
    }

    const overlapping = busyIntervals.filter(
      (b) => b.end > window.start && b.start < window.end
    );
    const busyWithLunch = [...overlapping, lunchFor(day)];
    const freeWindows = subtractBusy(window, busyWithLunch);

    const allSlots: DiscreteSlot[] = [];
    for (const win of freeWindows) {
      allSlots.push(...discretiseWindow(win, durationMinutes));
    }

    if (allSlots.length > 0) {
      days.push({
        dayStartISO: day.toISOString(),
        slots: allSlots,
      });
    }
  }

  return days;
}
