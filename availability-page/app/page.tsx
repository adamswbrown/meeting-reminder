import { config } from "@/lib/config";
import {
  computeAvailabilityForDuration,
  computeOOOPeriods,
  type DayOfDiscreteSlots,
} from "@/lib/availability";
import { fetchFreeBusy, fetchSyncState } from "@/lib/supabase";
import { BookingPage } from "@/components/BookingPage";
import { OOOBanner } from "@/components/OOOBanner";
import { StalenessPill } from "@/components/StalenessPill";

export const revalidate = 300;

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
