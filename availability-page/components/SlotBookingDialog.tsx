"use client";

import { useEffect, useRef, useState } from "react";
import { config } from "@/lib/config";
import type { SlotDescriptor } from "@/lib/booking";
import type { BookingQuestion } from "@/lib/eventTypes";
import { buildBookingPayload, createBooking } from "@/lib/bookingApi";

/** The event-type context a generic slot booking needs. */
export interface BookingContext {
  id: string;
  questions: BookingQuestion[];
}

interface Props {
  slot: SlotDescriptor | null;
  eventType: BookingContext;
  onClose: () => void;
}

type FormState = "idle" | "submitting" | "requested" | "slot_taken" | "error";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Modal booking form for a slot chosen on the availability view (no meeting
 * type pre-selected). Collects name/email + the configured intake questions
 * and inserts a pending booking — the same server flow as /book/[slug], so
 * the Mac app confirms it and emails the invite. Built on the native <dialog>
 * for focus trapping, ESC, and a backdrop, mirroring SlotActionsDialog.
 */
export function SlotBookingDialog({ slot, eventType, onClose }: Props) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const [state, setState] = useState<FormState>("idle");
  const [touched, setTouched] = useState(false);

  // Open/close imperatively, and reset the form each time a new slot opens.
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (slot && !dialog.open) {
      setName("");
      setEmail("");
      setAnswers({});
      setState("idle");
      setTouched(false);
      dialog.showModal();
    } else if (!slot && dialog.open) {
      dialog.close();
    }
  }, [slot]);

  // Mirror native close (ESC / .close()) into React state.
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    const handleClose = () => onClose();
    dialog.addEventListener("close", handleClose);
    return () => dialog.removeEventListener("close", handleClose);
  }, [onClose]);

  function handleBackdropClick(e: React.MouseEvent<HTMLDialogElement>) {
    if (e.target === e.currentTarget) onClose();
  }

  const emailValid = EMAIL_RE.test(email.trim());
  const canSubmit =
    name.trim().length > 0 &&
    emailValid &&
    eventType.questions.every(
      (q) => !q.required || (answers[q.id] ?? "").trim().length > 0
    );

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setTouched(true);
    if (!slot || !canSubmit) return;

    setState("submitting");
    const result = await createBooking(
      buildBookingPayload({
        eventTypeId: eventType.id,
        startISO: slot.startISO,
        endISO: slot.endISO,
        name: name.trim(),
        email: email.trim(),
        answers,
      })
    );
    if (result === "ok") setState("requested");
    else if (result === "slot_taken") setState("slot_taken");
    else setState("error");
  }

  const inputClass =
    "rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 focus:border-zinc-900 focus:outline-none focus:ring-1 focus:ring-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100 dark:focus:border-zinc-100 dark:focus:ring-zinc-100";

  return (
    <dialog
      ref={dialogRef}
      onClick={handleBackdropClick}
      className="fixed inset-0 m-auto h-fit w-full max-w-md rounded-2xl border border-zinc-200 bg-white p-0 text-zinc-900 shadow-xl backdrop:bg-zinc-900/60 backdrop:backdrop-blur-sm dark:border-zinc-800 dark:bg-zinc-950 dark:text-zinc-100"
    >
      {slot && (
        <div className="p-6">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h2 className="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-500">
                Request this slot
              </h2>
              <p className="mt-1 font-mono text-xl font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">
                {slot.visitorLabel ?? slot.ownerLabel}
                <span className="ml-2 text-xs uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
                  {slot.visitorTZAbbr ?? slot.ownerTZAbbr}
                </span>
              </p>
              <p className="mt-0.5 text-xs text-zinc-500 dark:text-zinc-500">
                {slot.dayLabel}
                {slot.visitorLabel && (
                  <>
                    {" "}&middot; {slot.ownerLabel} {slot.ownerTZAbbr} (Adam&rsquo;s
                    time)
                  </>
                )}
              </p>
            </div>
            <button
              type="button"
              onClick={onClose}
              aria-label="Close"
              className="rounded-md p-1 text-zinc-400 transition hover:bg-zinc-100 hover:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-200"
            >
              <svg
                width="18"
                height="18"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <path d="M18 6 6 18M6 6l12 12" />
              </svg>
            </button>
          </div>

          {state === "requested" ? (
            <div className="mt-6 rounded-xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-100">
              <p className="font-semibold">Requested</p>
              <p className="mt-1">
                Thanks{name.trim() ? `, ${name.trim().split(" ")[0]}` : ""} —
                your request is pending confirmation. You&rsquo;ll get a
                confirmation email at{" "}
                <span className="font-medium">{email.trim()}</span> once
                it&rsquo;s accepted.
              </p>
              <button
                type="button"
                onClick={onClose}
                className="mt-3 rounded-lg bg-emerald-600 px-3 py-1.5 text-sm font-medium text-white transition hover:bg-emerald-700"
              >
                Done
              </button>
            </div>
          ) : (
            <form onSubmit={handleSubmit} className="mt-6 flex flex-col gap-4" noValidate>
              {state === "slot_taken" && (
                <div
                  role="alert"
                  className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-100"
                >
                  That slot was just taken — please close this and pick another.
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

              <div className="flex flex-col gap-1">
                <label htmlFor="slot-name" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Name
                </label>
                <input
                  id="slot-name"
                  type="text"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  required
                  autoFocus
                  autoComplete="name"
                  className={inputClass}
                />
              </div>

              <div className="flex flex-col gap-1">
                <label htmlFor="slot-email" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Email
                </label>
                <input
                  id="slot-email"
                  type="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  required
                  autoComplete="email"
                  aria-invalid={touched && email.length > 0 && !emailValid}
                  className={inputClass}
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
                    htmlFor={`slot-q-${q.id}`}
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
                    id={`slot-q-${q.id}`}
                    value={answers[q.id] ?? ""}
                    onChange={(e) =>
                      setAnswers((prev) => ({ ...prev, [q.id]: e.target.value }))
                    }
                    required={q.required}
                    rows={2}
                    className={inputClass}
                  />
                </div>
              ))}

              <button
                type="submit"
                disabled={state === "submitting" || (touched && !canSubmit)}
                className="mt-1 inline-flex items-center justify-center rounded-lg bg-zinc-900 px-4 py-2.5 text-sm font-medium text-white transition hover:bg-zinc-700 focus:outline-none focus:ring-2 focus:ring-zinc-900 focus:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300 dark:focus:ring-zinc-100 dark:focus:ring-offset-zinc-950"
              >
                {state === "submitting" ? "Requesting…" : "Request this time"}
              </button>

              <p className="text-xs text-zinc-500 dark:text-zinc-500">
                This sends a request — it&rsquo;s confirmed by email once
                accepted, not booked instantly.
              </p>
            </form>
          )}
        </div>
      )}
    </dialog>
  );
}
