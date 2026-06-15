/**
 * Configuration for the availability page. Centralised so the page logic
 * stays declarative.
 */
export const config = {
  /** Owner — used in headings and the contact CTA. */
  ownerFirstName: "Adam Brown",
  ownerEmail: "adam.brown@altra.cloud",

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

  /** Bookable slot durations the visitor can pick from. */
  slotDurationsMinutes: [30, 45, 60] as ReadonlyArray<number>,

  /** Default duration if the visitor hasn't picked one. */
  defaultSlotMinutes: 30,

  /**
   * Slot starts are aligned to multiples of this (in minutes). 15 keeps
   * everything on the quarter-hour regardless of which duration is picked.
   */
  slotAlignmentMinutes: 15,

  /** How many days ahead to render, including today. */
  lookAheadDays: 14,

  /**
   * Civilised hours in the VISITOR's timezone. Slots whose START falls
   * outside this range are hidden by default. A "Show all hours" toggle
   * appears for non-London visitors to override.
   */
  visitorVisibleStartHour: 8,
  visitorVisibleEndHour: 20,

  /**
   * How long the page caches a fetched snapshot before refetching from
   * Supabase. 5 minutes keeps us well inside the 30-min drift budget.
   */
  revalidateSeconds: 300,

  /** Above this many minutes since last Mac push, show a stale warning. */
  stalenessWarnAfterMinutes: 120,
} as const;
