/**
 * Configuration for the availability page. Centralised so the page logic
 * stays declarative.
 */
export const config = {
  /** Owner — used in headings and the contact CTA. */
  ownerFirstName: "Adam",
  ownerEmail: "adam@askadam.cloud",

  /** Canonical timezone for the working day. */
  timezone: "Europe/London" as const,

  /** Working hours in the owner's timezone, 24-hour. */
  workdayStartHour: 9,
  workdayEndHour: 17,

  /** Blocked-out lunch slot in the owner's timezone. */
  lunchStartHour: 12,
  lunchStartMinute: 30,
  lunchEndHour: 13,
  lunchEndMinute: 30,

  /** Working days, 0 = Sunday … 6 = Saturday. */
  workdays: [1, 2, 3, 4, 5] as ReadonlyArray<number>,

  /** Minimum slot length displayed, in minutes. */
  minSlotMinutes: 45,

  /** How many days ahead to render, including today. */
  lookAheadDays: 14,

  /**
   * How long the page caches a fetched snapshot before refetching from
   * Supabase. 5 minutes keeps us well inside the user's 30-min drift budget
   * even if Vercel's edge cache is fully warm.
   */
  revalidateSeconds: 300,

  /**
   * Threshold above which the page warns visitors the data may be stale.
   * The Mac pushes every 5 min, so anything older than 2 hours means the
   * Mac has been asleep / offline.
   */
  stalenessWarnAfterMinutes: 120,
} as const;
