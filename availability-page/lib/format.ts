import { tz } from "@date-fns/tz";
import { differenceInCalendarDays, format } from "date-fns";
import { config } from "./config";

/**
 * Format helpers for rendering a slot in both the owner's timezone and the
 * visitor's timezone. The visitor's timezone is only known on the client, so
 * the page renders in the owner's tz first and a small client component
 * adds the visitor-time annotation after hydration.
 */

const ownerTZ = tz(config.timezone);

/** "14:30" in the owner's timezone (24h). */
export function formatTimeInOwnerTZ(d: Date): string {
  return format(d, "HH:mm", { in: ownerTZ });
}

/** "BST" or "GMT" depending on the date. */
export function ownerTZAbbreviation(d: Date): string {
  return (
    new Intl.DateTimeFormat("en-GB", {
      timeZone: config.timezone,
      timeZoneName: "short",
    })
      .formatToParts(d)
      .find((p) => p.type === "timeZoneName")?.value ?? ""
  );
}

/**
 * "Today", "Tomorrow", "Mon 26 May" — relative to `now` in the owner's tz.
 */
export function formatDayHeading(day: Date, now: Date): string {
  const diff = differenceInCalendarDays(day, now, { in: ownerTZ });
  if (diff === 0) return "Today";
  if (diff === 1) return "Tomorrow";
  return format(day, "EEEE d MMMM", { in: ownerTZ });
}

/** "22 May" — short label paired with the heading above. */
export function formatDayDate(day: Date): string {
  return format(day, "d MMM", { in: ownerTZ });
}

/** ISO-ish "last updated" relative string: "3 min ago", "2 hours ago", … */
export function formatRelativeTime(date: Date, now: Date): string {
  const ms = now.getTime() - date.getTime();
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} hour${hours === 1 ? "" : "s"} ago`;
  const days = Math.floor(hours / 24);
  return `${days} day${days === 1 ? "" : "s"} ago`;
}
