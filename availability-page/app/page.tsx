import { config } from "@/lib/config";
import { computeAvailability } from "@/lib/availability";
import {
  formatDayDate,
  formatDayHeading,
  formatTimeInOwnerTZ,
  ownerTZAbbreviation,
} from "@/lib/format";
import { fetchFreeBusy, fetchSyncState } from "@/lib/supabase";
import { SlotCard } from "@/components/SlotCard";
import { StalenessPill } from "@/components/StalenessPill";

// The Supabase fetches themselves carry next.revalidate, but set the page-level
// hint too so the prerender is regenerated on schedule.
export const revalidate = 300;

export default async function Page() {
  const now = new Date();
  const [events, syncState] = await Promise.all([
    fetchFreeBusy(),
    fetchSyncState(),
  ]);

  const lastSyncedAt = syncState ? new Date(syncState.last_synced_at) : null;
  const days = computeAvailability(events, now);
  const hasAnySlots = days.some((d) => d.slots.length > 0);

  return (
    <main className="mx-auto w-full max-w-2xl px-6 py-12 sm:py-20">
      <header className="mb-10 flex flex-col gap-3">
        <h1 className="text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50 sm:text-3xl">
          When is {config.ownerFirstName} free?
        </h1>
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          Times shown in London ({ownerTZAbbreviation(now)}). Click any slot
          to copy.
        </p>
        <div>
          <StalenessPill lastSyncedAt={lastSyncedAt} now={now} />
        </div>
      </header>

      {hasAnySlots ? (
        <div className="flex flex-col gap-8">
          {days.map((day) =>
            day.slots.length === 0 ? null : (
              <section key={day.dayStart.toISOString()}>
                <div className="mb-3 flex items-baseline justify-between">
                  <h2 className="text-sm font-semibold uppercase tracking-wide text-zinc-700 dark:text-zinc-300">
                    {formatDayHeading(day.dayStart, now)}
                  </h2>
                  <span className="text-xs text-zinc-500 dark:text-zinc-500">
                    {formatDayDate(day.dayStart)}
                  </span>
                </div>
                <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                  {day.slots.map((slot) => {
                    const ownerLabel = `${formatTimeInOwnerTZ(
                      slot.start
                    )}–${formatTimeInOwnerTZ(slot.end)}`;
                    return (
                      <SlotCard
                        key={slot.start.toISOString()}
                        startISO={slot.start.toISOString()}
                        endISO={slot.end.toISOString()}
                        ownerLabel={ownerLabel}
                        ownerTZAbbr={ownerTZAbbreviation(slot.start)}
                        dayLabel={formatDayHeading(day.dayStart, now)}
                      />
                    );
                  })}
                </div>
              </section>
            )
          )}
        </div>
      ) : (
        <div className="rounded-xl border border-zinc-200 bg-zinc-50 p-6 text-sm text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
          Nothing free in the next {config.lookAheadDays} working days —
          email{" "}
          <a
            href={`mailto:${config.ownerEmail}`}
            className="font-medium text-zinc-900 underline underline-offset-2 dark:text-zinc-100"
          >
            {config.ownerEmail}
          </a>{" "}
          and we&rsquo;ll find a way.
        </div>
      )}

      <footer className="mt-16 border-t border-zinc-200 pt-6 text-sm text-zinc-600 dark:border-zinc-800 dark:text-zinc-400">
        Reply with a slot that works, or email{" "}
        <a
          href={`mailto:${config.ownerEmail}`}
          className="font-medium text-zinc-900 underline underline-offset-2 dark:text-zinc-100"
        >
          {config.ownerEmail}
        </a>
        .
      </footer>
    </main>
  );
}
