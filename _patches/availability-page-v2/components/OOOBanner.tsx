import { tz } from "@date-fns/tz";
import { format, startOfDay } from "date-fns";
import { config } from "@/lib/config";
import { nextWorkingDay, type OOOPeriod } from "@/lib/availability";

const ownerTZ = tz(config.timezone);

/** "Mon 26 May" in the owner's timezone. */
function dayLabel(d: Date): string {
  return format(d, "EEE d MMM", { in: ownerTZ });
}

/**
 * Build a human sentence for one OOO period relative to `now`.
 *
 * - Ongoing (started on/before today): "out of office until X, back Y"
 * - Upcoming single day: "out of office on X"
 * - Upcoming range: "out of office X – Y"
 */
function describe(period: OOOPeriod, now: Date): string {
  const today = startOfDay(now, { in: ownerTZ });
  const first = new Date(period.firstDayISO);
  const last = new Date(period.lastDayISO);
  const name = config.ownerFirstName.split(" ")[0];

  const ongoing = first.getTime() <= today.getTime();
  const lastIsToday = last.getTime() === today.getTime();
  const back = dayLabel(nextWorkingDay(last));

  if (ongoing) {
    if (lastIsToday) {
      return `${name} is out of office today — back ${back}.`;
    }
    return `${name} is out of office until ${dayLabel(last)} — back ${back}.`;
  }

  if (first.getTime() === last.getTime()) {
    return `${name} is out of office on ${dayLabel(first)}.`;
  }
  return `${name} is out of office ${dayLabel(first)} – ${dayLabel(last)}.`;
}

export function OOOBanner({
  periods,
  nowISO,
}: {
  periods: OOOPeriod[];
  nowISO: string;
}) {
  if (periods.length === 0) return null;
  const now = new Date(nowISO);

  return (
    <div className="mb-6 flex flex-col gap-1 rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-500/40 dark:bg-amber-500/10 dark:text-amber-200">
      {periods.map((p) => (
        <p key={p.firstDayISO} className="font-medium">
          {describe(p, now)}
        </p>
      ))}
      <p className="text-xs font-normal text-amber-700/80 dark:text-amber-300/70">
        Slots on those days are hidden. Pick another time below, or email{" "}
        <a
          href={`mailto:${config.ownerEmail}`}
          className="underline underline-offset-2"
        >
          {config.ownerEmail}
        </a>
        .
      </p>
    </div>
  );
}
