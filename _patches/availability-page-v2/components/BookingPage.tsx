"use client";

import { useMemo, useState, useSyncExternalStore } from "react";
import { config } from "@/lib/config";
import { formatDayDate, formatDayHeading } from "@/lib/format";
import { SlotCard } from "./SlotCard";

interface Slot {
  startISO: string;
  endISO: string;
}
interface Day {
  dayStartISO: string;
  slots: Slot[];
}
interface Props {
  slotsByDuration: Record<number, Day[]>;
  nowISO: string;
}

// useSyncExternalStore pattern: SSR returns London (so the static shell
// renders London-first), client hydrates with the real visitor timezone
// without tripping React's hydration warnings.
const subscribe = () => () => {};
const getVisitorTZ = () => Intl.DateTimeFormat().resolvedOptions().timeZone;
const getServerTZ = () => config.timezone;

/**
 * Returns true when the slot's START hour, expressed in the visitor's
 * timezone, falls within the configured "civilised" window. Used to hide
 * 03:00-EDT slots from a New York visitor by default.
 */
function isInVisitorHours(startISO: string, tzName: string): boolean {
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: tzName,
    hour: "2-digit",
    hour12: false,
  });
  const hour = parseInt(fmt.format(new Date(startISO)), 10);
  return (
    hour >= config.visitorVisibleStartHour &&
    hour < config.visitorVisibleEndHour
  );
}

export function BookingPage({ slotsByDuration, nowISO }: Props) {
  const [duration, setDuration] = useState<number>(config.defaultSlotMinutes);
  const [showAll, setShowAll] = useState(false);

  const visitorTZ = useSyncExternalStore(
    subscribe,
    getVisitorTZ,
    getServerTZ
  );
  const visitorIsLondon = visitorTZ === config.timezone;

  const now = useMemo(() => new Date(nowISO), [nowISO]);
  const days = slotsByDuration[duration] ?? [];

  const filtered = useMemo(() => {
    if (showAll || visitorIsLondon) return days;
    return days
      .map((d) => ({
        ...d,
        slots: d.slots.filter((s) => isInVisitorHours(s.startISO, visitorTZ)),
      }))
      .filter((d) => d.slots.length > 0);
  }, [days, showAll, visitorIsLondon, visitorTZ]);

  const hasAny = filtered.some((d) => d.slots.length > 0);
  const totalHidden = useMemo(
    () =>
      visitorIsLondon || showAll
        ? 0
        : days.reduce((sum, d) => sum + d.slots.length, 0) -
          filtered.reduce((sum, d) => sum + d.slots.length, 0),
    [days, filtered, visitorIsLondon, showAll]
  );

  return (
    <>
      <div className="mb-6 flex flex-wrap items-center gap-3">
        <span className="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-500">
          Duration
        </span>
        <div
          role="radiogroup"
          aria-label="Meeting duration"
          className="flex gap-1 rounded-lg bg-zinc-100 p-1 dark:bg-zinc-900"
        >
          {config.slotDurationsMinutes.map((d) => {
            const active = duration === d;
            return (
              <button
                key={d}
                role="radio"
                aria-checked={active}
                onClick={() => setDuration(d)}
                className={`rounded-md px-3 py-1 text-sm font-medium transition ${
                  active
                    ? "bg-white text-zinc-900 shadow-sm dark:bg-zinc-700 dark:text-zinc-50"
                    : "text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100"
                }`}
              >
                {d} min
              </button>
            );
          })}
        </div>

        {!visitorIsLondon && (
          <label className="ml-auto flex cursor-pointer items-center gap-2 text-xs text-zinc-600 dark:text-zinc-400">
            <input
              type="checkbox"
              checked={showAll}
              onChange={(e) => setShowAll(e.target.checked)}
              className="size-3.5"
            />
            Show all hours
            {totalHidden > 0 && (
              <span className="text-zinc-400 dark:text-zinc-500">
                ({totalHidden} hidden)
              </span>
            )}
          </label>
        )}
      </div>

      {hasAny ? (
        <div className="flex flex-col gap-8">
          {filtered.map((day) => (
            <section key={day.dayStartISO}>
              <div className="mb-3 flex items-baseline justify-between">
                <h2 className="text-sm font-semibold uppercase tracking-wide text-zinc-700 dark:text-zinc-300">
                  {formatDayHeading(new Date(day.dayStartISO), now)}
                </h2>
                <span className="text-xs text-zinc-500 dark:text-zinc-500">
                  {formatDayDate(new Date(day.dayStartISO))}
                </span>
              </div>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                {day.slots.map((slot) => (
                  <SlotCard
                    key={slot.startISO}
                    startISO={slot.startISO}
                    endISO={slot.endISO}
                    dayLabel={formatDayHeading(new Date(day.dayStartISO), now)}
                  />
                ))}
              </div>
            </section>
          ))}
        </div>
      ) : (
        <div className="rounded-xl border border-zinc-200 bg-zinc-50 p-6 text-sm text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
          {visitorIsLondon || showAll ? (
            <>
              Nothing free in the next {config.lookAheadDays} working days
              &mdash; email{" "}
              <a
                href={`mailto:${config.ownerEmail}`}
                className="font-medium text-zinc-900 underline underline-offset-2 dark:text-zinc-100"
              >
                {config.ownerEmail}
              </a>{" "}
              and we&rsquo;ll find a way.
            </>
          ) : (
            <>
              Nothing in your typical hours &mdash; tick &ldquo;Show all
              hours&rdquo; above to see everything, or email{" "}
              <a
                href={`mailto:${config.ownerEmail}`}
                className="font-medium text-zinc-900 underline underline-offset-2 dark:text-zinc-100"
              >
                {config.ownerEmail}
              </a>
              .
            </>
          )}
        </div>
      )}
    </>
  );
}
