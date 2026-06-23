"use client";

import { useMemo, useState, useSyncExternalStore } from "react";
import { useRouter } from "next/navigation";
import { config } from "@/lib/config";
import { formatDayHeading } from "@/lib/format";
import type { BookingQuestion } from "@/lib/eventTypes";
import type { BookingSlot } from "@/lib/bookingSlots";
import { buildBookingPayload, createBooking } from "@/lib/bookingApi";

/** The subset of EventType the form needs — serializable from the server. */
interface EventTypeLite {
  id: string;
  title: string;
  durationMin: number;
  questions: BookingQuestion[];
}

interface Props {
  eventType: EventTypeLite;
  /** Generated slots, already ISO strings (RSC→client safe). */
  slots: BookingSlot[];
  /** Owner IANA timezone, e.g. "Europe/London". */
  ownerTZ: string;
}

type FormState = "idle" | "submitting" | "requested" | "slot_taken" | "error";

// useSyncExternalStore pattern (mirrors SlotCard): SSR renders London, the
// client hydrates with the visitor's real timezone without hydration warnings.
const subscribe = () => () => {};
const getVisitorTZ = () => Intl.DateTimeFormat().resolvedOptions().timeZone;
const getServerTZ = () => config.timezone;

/** Wall-clock range like "14:30–15:30" in the given tz (24h, en-GB). */
function formatRange(start: Date, end: Date, tzName: string): string {
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: tzName,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  return `${fmt.format(start)}–${fmt.format(end)}`;
}

/** Short tz abbreviation like "BST" / "EDT" for a zone at a given instant. */
function tzAbbreviation(tzName: string, at: Date): string {
  const fmt = new Intl.DateTimeFormat("en-GB", {
    timeZone: tzName,
    timeZoneName: "short",
  });
  return (
    fmt.formatToParts(at).find((p) => p.type === "timeZoneName")?.value ?? ""
  );
}

/** "America/New_York" → "New York". */
function prettifyTZName(tzName: string): string {
  const parts = tzName.split("/");
  return (parts[parts.length - 1] ?? tzName).replace(/_/g, " ");
}

interface DayGroup {
  dayStartISO: string;
  slots: BookingSlot[];
}

/** Group slots by owner-tz calendar day, preserving chronological order. */
function groupByDay(slots: BookingSlot[], ownerTZ: string): DayGroup[] {
  const dayKey = new Intl.DateTimeFormat("en-CA", {
    timeZone: ownerTZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  const groups: DayGroup[] = [];
  let current: DayGroup | null = null;
  let currentKey = "";
  for (const slot of slots) {
    const key = dayKey.format(new Date(slot.startISO));
    if (!current || key !== currentKey) {
      current = { dayStartISO: slot.startISO, slots: [] };
      currentKey = key;
      groups.push(current);
    }
    current.slots.push(slot);
  }
  return groups;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function BookingForm({ eventType, slots, ownerTZ }: Props) {
  const router = useRouter();

  const visitorTZ = useSyncExternalStore(subscribe, getVisitorTZ, getServerTZ);
  const visitorIsOwnerTZ = visitorTZ === ownerTZ;

  const [selected, setSelected] = useState<BookingSlot | null>(null);
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const [state, setState] = useState<FormState>("idle");
  const [touched, setTouched] = useState(false);

  const days = useMemo(() => groupByDay(slots, ownerTZ), [slots, ownerTZ]);
  const now = useMemo(() => new Date(), []);

  const emailValid = EMAIL_RE.test(email.trim());
  const canSubmit =
    selected !== null &&
    name.trim().length > 0 &&
    emailValid &&
    eventType.questions.every(
      (q) => !q.required || (answers[q.id] ?? "").trim().length > 0
    );

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setTouched(true);
    if (!selected || !canSubmit) return;

    setState("submitting");
    const result = await createBooking(
      buildBookingPayload({
        eventTypeId: eventType.id,
        startISO: selected.startISO,
        endISO: selected.endISO,
        name: name.trim(),
        email: email.trim(),
        answers,
      })
    );

    if (result === "ok") {
      setState("requested");
    } else if (result === "slot_taken") {
      setState("slot_taken");
      setSelected(null);
      // Pull a fresh slot list so the taken slot disappears.
      router.refresh();
    } else {
      setState("error");
    }
  }

  // ---- Requested (success) state -----------------------------------------
  if (state === "requested") {
    return (
      <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-6 text-sm text-emerald-900 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-100">
        <h2 className="mb-2 text-lg font-semibold">Requested</h2>
        <p>
          Thanks{name.trim() ? `, ${name.trim().split(" ")[0]}` : ""} — your
          request is pending confirmation. You&rsquo;ll get a confirmation email
          at <span className="font-medium">{email.trim()}</span> shortly once
          it&rsquo;s accepted.
        </p>
      </div>
    );
  }

  const visitorTZAbbr = tzAbbreviation(visitorTZ, now);
  const ownerTZAbbr = tzAbbreviation(ownerTZ, now);

  return (
    <div className="flex flex-col gap-8">
      <p className="text-xs text-zinc-500 dark:text-zinc-500">
        {visitorIsOwnerTZ ? (
          <>
            Times shown in {visitorTZAbbr} &middot; {prettifyTZName(visitorTZ)}
          </>
        ) : (
          <>
            Times shown in your local time &middot; {visitorTZAbbr} (
            {prettifyTZName(visitorTZ)}) &middot; owner is in {ownerTZAbbr}{" "}
            {prettifyTZName(ownerTZ)}
          </>
        )}
      </p>

      {state === "slot_taken" && (
        <div
          role="alert"
          className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-100"
        >
          That slot was just taken — please pick another below.
        </div>
      )}
      {state === "error" && (
        <div
          role="alert"
          className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-900 dark:border-red-900 dark:bg-red-950 dark:text-red-100"
        >
          Something went wrong — please try again or email{" "}
          <a
            href={`mailto:${config.ownerEmail}`}
            className="font-medium underline underline-offset-2"
          >
            {config.ownerEmail}
          </a>
          .
        </div>
      )}

      {/* ---- Slot picker --------------------------------------------------- */}
      <section>
        <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-zinc-700 dark:text-zinc-300">
          Pick a time
        </h2>
        {days.length === 0 ? (
          <div className="rounded-xl border border-zinc-200 bg-zinc-50 p-6 text-sm text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
            Nothing free in the next {config.lookAheadDays} days — email{" "}
            <a
              href={`mailto:${config.ownerEmail}`}
              className="font-medium text-zinc-900 underline underline-offset-2 dark:text-zinc-100"
            >
              {config.ownerEmail}
            </a>{" "}
            and we&rsquo;ll find a way.
          </div>
        ) : (
          <div className="flex flex-col gap-6">
            {days.map((day) => (
              <div key={day.dayStartISO}>
                <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-500">
                  {formatDayHeading(new Date(day.dayStartISO), now)}
                </h3>
                <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                  {day.slots.map((slot) => {
                    const start = new Date(slot.startISO);
                    const end = new Date(slot.endISO);
                    const label = formatRange(start, end, visitorTZ);
                    const isSelected =
                      selected?.startISO === slot.startISO;
                    return (
                      <button
                        key={slot.startISO}
                        type="button"
                        onClick={() => {
                          setSelected(slot);
                          if (state !== "idle") setState("idle");
                        }}
                        aria-pressed={isSelected}
                        aria-label={`Select ${label} ${visitorTZAbbr}`}
                        className={`flex flex-col items-start rounded-xl border px-4 py-3 text-left transition focus:outline-none focus:ring-2 focus:ring-zinc-900 dark:focus:ring-zinc-100 ${
                          isSelected
                            ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                            : "border-zinc-200 bg-white text-zinc-900 hover:border-zinc-300 hover:shadow-sm dark:border-zinc-800 dark:bg-zinc-950 dark:text-zinc-100 dark:hover:border-zinc-700"
                        }`}
                      >
                        <span className="font-mono text-base font-medium tabular-nums">
                          {label}
                        </span>
                        <span
                          className={`mt-0.5 text-xs uppercase tracking-wide ${
                            isSelected
                              ? "text-zinc-300 dark:text-zinc-600"
                              : "text-zinc-500 dark:text-zinc-400"
                          }`}
                        >
                          {visitorTZAbbr}
                        </span>
                      </button>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
        )}
      </section>

      {/* ---- Details form -------------------------------------------------- */}
      {days.length > 0 && (
        <form onSubmit={handleSubmit} className="flex flex-col gap-4" noValidate>
          <h2 className="text-sm font-semibold uppercase tracking-wide text-zinc-700 dark:text-zinc-300">
            Your details
          </h2>

          <div className="flex flex-col gap-1">
            <label
              htmlFor="booking-name"
              className="text-sm font-medium text-zinc-700 dark:text-zinc-300"
            >
              Name
            </label>
            <input
              id="booking-name"
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              autoComplete="name"
              className="rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 focus:border-zinc-900 focus:outline-none focus:ring-1 focus:ring-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100 dark:focus:border-zinc-100 dark:focus:ring-zinc-100"
            />
          </div>

          <div className="flex flex-col gap-1">
            <label
              htmlFor="booking-email"
              className="text-sm font-medium text-zinc-700 dark:text-zinc-300"
            >
              Email
            </label>
            <input
              id="booking-email"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
              autoComplete="email"
              aria-invalid={touched && email.length > 0 && !emailValid}
              className="rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 focus:border-zinc-900 focus:outline-none focus:ring-1 focus:ring-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100 dark:focus:border-zinc-100 dark:focus:ring-zinc-100"
            />
            {touched && email.length > 0 && !emailValid && (
              <span className="text-xs text-red-600 dark:text-red-400">
                Enter a valid email address.
              </span>
            )}
          </div>

          {eventType.questions.map((q) => (
            <div key={q.id} className="flex flex-col gap-1">
              <label
                htmlFor={`booking-q-${q.id}`}
                className="text-sm font-medium text-zinc-700 dark:text-zinc-300"
              >
                {q.label}
                {q.required && (
                  <span className="ml-1 text-zinc-400" aria-hidden="true">
                    *
                  </span>
                )}
              </label>
              <textarea
                id={`booking-q-${q.id}`}
                value={answers[q.id] ?? ""}
                onChange={(e) =>
                  setAnswers((prev) => ({ ...prev, [q.id]: e.target.value }))
                }
                required={q.required}
                rows={3}
                className="rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 focus:border-zinc-900 focus:outline-none focus:ring-1 focus:ring-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100 dark:focus:border-zinc-100 dark:focus:ring-zinc-100"
              />
            </div>
          ))}

          {touched && !selected && (
            <span className="text-xs text-red-600 dark:text-red-400">
              Pick a time above first.
            </span>
          )}

          <button
            type="submit"
            disabled={state === "submitting" || (touched && !canSubmit)}
            className="mt-2 inline-flex items-center justify-center rounded-lg bg-zinc-900 px-4 py-2.5 text-sm font-medium text-white transition hover:bg-zinc-700 focus:outline-none focus:ring-2 focus:ring-zinc-900 focus:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300 dark:focus:ring-zinc-100 dark:focus:ring-offset-zinc-950"
          >
            {state === "submitting"
              ? "Requesting…"
              : selected
                ? `Request ${eventType.durationMin} min`
                : "Request booking"}
          </button>

          <p className="text-xs text-zinc-500 dark:text-zinc-500">
            This sends a request — it&rsquo;s confirmed by email once accepted,
            not booked instantly.
          </p>
        </form>
      )}
    </div>
  );
}
