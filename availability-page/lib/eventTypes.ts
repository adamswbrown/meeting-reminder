import { rest } from "./supabase";

/**
 * A booking event type — the "kind" of meeting a visitor can book (e.g. a
 * 30-minute intro call). Mirrors the `booking_event_types` Supabase table but
 * in camelCase, with `hours` typed as a weekday→ranges map.
 */

/** "HH:mm" pair: [start, end] in Europe/London. */
export type TimeRange = [string, string];

export type Weekday = "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun";

/** Bookable hours per weekday, each an array of [start, end] "HH:mm" ranges. */
export type WeekHours = Record<Weekday, TimeRange[]>;

export interface BookingQuestion {
  id: string;
  label: string;
  required: boolean;
}

export interface EventType {
  id: string;
  slug: string;
  title: string;
  description: string | null;
  durationMin: number;
  bufferBefore: number;
  bufferAfter: number;
  minNoticeMin: number;
  maxPerDay: number | null;
  hours: WeekHours;
  questions: BookingQuestion[];
  active: boolean;
}

/** The raw snake_case row as returned by PostgREST (hours jsonb already parsed). */
export interface EventTypeRow {
  id: string;
  slug: string;
  title: string;
  description: string | null;
  duration_min: number;
  buffer_before: number;
  buffer_after: number;
  min_notice_min: number;
  max_per_day: number | null;
  hours: Partial<Record<Weekday, TimeRange[]>> | null;
  questions: BookingQuestion[] | null;
  active: boolean;
}

const WEEKDAYS: Weekday[] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

const SELECT =
  "id,slug,title,description,duration_min,buffer_before,buffer_after," +
  "min_notice_min,max_per_day,hours,questions,active";

/**
 * Map a snake_case PostgREST row to a typed, camelCase {@link EventType}.
 * Pure — no I/O. Missing weekdays in `hours` default to an empty range list.
 */
export function parseEventType(row: EventTypeRow): EventType {
  const hours = {} as WeekHours;
  for (const day of WEEKDAYS) {
    hours[day] = row.hours?.[day] ?? [];
  }

  return {
    id: row.id,
    slug: row.slug,
    title: row.title,
    description: row.description ?? null,
    durationMin: row.duration_min,
    bufferBefore: row.buffer_before,
    bufferAfter: row.buffer_after,
    minNoticeMin: row.min_notice_min,
    maxPerDay: row.max_per_day ?? null,
    hours,
    questions: row.questions ?? [],
    active: row.active,
  };
}

/** Fetch a single active event type by slug, or null if not found. */
export async function fetchEventType(slug: string): Promise<EventType | null> {
  const params = new URLSearchParams({
    slug: `eq.${slug}`,
    active: "eq.true",
    select: SELECT,
    limit: "1",
  });
  const query = params.toString().replace(/%2C/g, ",");
  const rows = await rest<EventTypeRow[]>(`booking_event_types?${query}`);
  return rows[0] ? parseEventType(rows[0]) : null;
}

/** Fetch all active event types, ordered by duration then title. */
export async function fetchActiveEventTypes(): Promise<EventType[]> {
  const params = new URLSearchParams({
    active: "eq.true",
    select: SELECT,
    order: "duration_min.asc,title.asc",
  });
  const query = params.toString().replace(/%2C/g, ",");
  const rows = await rest<EventTypeRow[]>(`booking_event_types?${query}`);
  return rows.map(parseEventType);
}
