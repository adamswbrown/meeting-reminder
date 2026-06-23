import { config } from "@/lib/config";
import { fetchEventType } from "@/lib/eventTypes";
import { fetchFreeBusy } from "@/lib/supabase";
import { fetchBookedSlots, generateSlots } from "@/lib/bookingSlots";
import { BookingForm } from "@/components/BookingForm";

/**
 * Visitor-facing booking page for a single event type, e.g. `/book/intro-30`.
 *
 * Marked `force-dynamic` so it fetches free/busy + booked slots at request
 * time. We deliberately avoid static prerender here — the data is live and the
 * shared Supabase-backed fetch shouldn't run at build time.
 */
export const dynamic = "force-dynamic";

interface PageProps {
  // Next 15+/16: params is async and must be awaited.
  params: Promise<{ slug: string }>;
}

function Unavailable() {
  return (
    <main className="mx-auto w-full max-w-2xl px-6 py-12 sm:py-20">
      <div className="rounded-xl border border-zinc-200 bg-zinc-50 p-6 text-sm text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
        <h1 className="mb-2 text-lg font-semibold text-zinc-900 dark:text-zinc-50">
          This booking link isn&rsquo;t available
        </h1>
        <p>
          The link may be wrong or no longer active. Email{" "}
          <a
            href={`mailto:${config.ownerEmail}`}
            className="font-medium text-zinc-900 underline underline-offset-2 dark:text-zinc-100"
          >
            {config.ownerEmail}
          </a>{" "}
          and we&rsquo;ll sort something out.
        </p>
      </div>
    </main>
  );
}

export default async function Page({ params }: PageProps) {
  const { slug } = await params;

  const eventType = await fetchEventType(slug);
  if (!eventType) {
    return <Unavailable />;
  }

  const [freeBusy, bookedSlots] = await Promise.all([
    fetchFreeBusy(),
    fetchBookedSlots(),
  ]);

  const now = new Date();
  const slots = generateSlots({
    eventType,
    freeBusy,
    bookedSlots,
    now,
    lookAheadDays: config.lookAheadDays,
  });

  return (
    <main className="mx-auto w-full max-w-2xl px-6 py-12 sm:py-20">
      <header className="mb-8 flex flex-col gap-3">
        <h1 className="text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50 sm:text-3xl">
          {eventType.title}
        </h1>
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          {eventType.durationMin} min with {config.ownerFirstName}
          {eventType.description ? <> &middot; {eventType.description}</> : null}
        </p>
      </header>

      <BookingForm
        eventType={{
          id: eventType.id,
          title: eventType.title,
          durationMin: eventType.durationMin,
          questions: eventType.questions,
        }}
        slots={slots}
        ownerTZ={config.timezone}
      />

      <footer className="mt-16 border-t border-zinc-200 pt-6 text-sm text-zinc-600 dark:border-zinc-800 dark:text-zinc-400">
        Prefer email? Reach {config.ownerFirstName} at{" "}
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
