import Link from "next/link";
import { config } from "@/lib/config";
import {
  computeAvailabilityForDuration,
  computeOOOPeriods,
  type DayOfDiscreteSlots,
} from "@/lib/availability";
import { fetchFreeBusy, fetchSyncState } from "@/lib/supabase";
import { fetchActiveEventTypes, type EventType } from "@/lib/eventTypes";
import { BookingPage } from "@/components/BookingPage";
import { OOOBanner } from "@/components/OOOBanner";
import { StalenessPill } from "@/components/StalenessPill";

export const revalidate = 300;

/**
 * Discoverability section listing the active booking event types, each
 * linking to its self-service booking page. Resilient: any fetch failure or
 * empty list renders nothing rather than breaking the homepage.
 */
async function BookACallSection() {
  let eventTypes: EventType[] = [];
  try {
    eventTypes = await fetchActiveEventTypes();
  } catch {
    return null;
  }
  if (eventTypes.length === 0) return null;

  return (
    <section className="mb-10">
      <h2 className="text-lg font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">
        Book a call
      </h2>
      <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
        Pick a meeting type to see open times and book.
      </p>
      <ul className="mt-4 flex flex-col gap-3">
        {eventTypes.map((et) => (
          <li key={et.id}>
            <Link
              href={`/book/${et.slug}`}
              className="group flex items-center justify-between gap-4 rounded-xl border border-zinc-200 bg-white px-4 py-3 transition hover:border-zinc-300 hover:shadow-sm focus:outline-none focus:ring-2 focus:ring-zinc-900 dark:border-zinc-800 dark:bg-zinc-950 dark:hover:border-zinc-700 dark:focus:ring-zinc-100"
            >
              <span className="flex flex-col gap-0.5">
                <span className="flex items-baseline gap-2">
                  <span className="font-medium text-zinc-900 dark:text-zinc-100">
                    {et.title}
                  </span>
                  <span className="text-xs uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
                    {et.durationMin} min
                  </span>
                </span>
                {et.description && (
                  <span className="text-sm text-zinc-600 dark:text-zinc-400">
                    {et.description}
                  </span>
                )}
              </span>
              <span className="shrink-0 text-sm font-medium text-zinc-500 transition group-hover:text-zinc-900 dark:text-zinc-400 dark:group-hover:text-zinc-100">
                Book &rarr;
              </span>
            </Link>
          </li>
        ))}
      </ul>
    </section>
  );
}

export default async function Page() {
  const now = new Date();
  const [events, syncState] = await Promise.all([
    fetchFreeBusy(),
    fetchSyncState(),
  ]);

  const lastSyncedAt = syncState ? new Date(syncState.last_synced_at) : null;

  // Precompute slots for each duration the visitor can pick from. The arrays
  // are small (~hundreds of slots total) so sending them all to the client
  // and switching with no network round-trip is the simplest design.
  const slotsByDuration: Record<number, DayOfDiscreteSlots[]> = {};
  for (const duration of config.slotDurationsMinutes) {
    slotsByDuration[duration] = computeAvailabilityForDuration(
      events,
      duration,
      now
    );
  }

  const oooPeriods = computeOOOPeriods(events, now);

  return (
    <main className="mx-auto w-full max-w-2xl px-6 py-12 sm:py-20">
      <header className="mb-8 flex flex-col gap-3">
        <h1 className="text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50 sm:text-3xl">
          Book a meeting with {config.ownerFirstName}
        </h1>
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          Pick a duration, then click a slot to copy a ready-made reply.
        </p>
        <div>
          <StalenessPill lastSyncedAt={lastSyncedAt} now={now} />
        </div>
      </header>

      <OOOBanner periods={oooPeriods} nowISO={now.toISOString()} />

      <BookACallSection />

      <BookingPage
        slotsByDuration={slotsByDuration}
        nowISO={now.toISOString()}
      />

      <footer className="mt-16 border-t border-zinc-200 pt-6 text-sm text-zinc-600 dark:border-zinc-800 dark:text-zinc-400">
        Pick a slot and send it back, or email{" "}
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
