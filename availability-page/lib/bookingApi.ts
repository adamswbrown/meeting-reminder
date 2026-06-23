import { REST_BASE, anonHeaders } from "./supabase";

/**
 * Client for inserting a booking request into Supabase. The pure functions
 * (`buildBookingPayload`, `classifyInsertResult`) hold the logic; `createBooking`
 * is a thin network wrapper over PostgREST that delegates to both.
 */

export interface BuildPayloadArgs {
  eventTypeId: string;
  startISO: string;
  endISO: string;
  name: string;
  email: string;
  answers: Record<string, unknown>;
}

/** The exact object POSTed to `booking_requests`. */
export interface BookingPayload {
  event_type_id: string;
  start_utc: string;
  end_utc: string;
  booker_name: string;
  booker_email: string;
  answers: Record<string, unknown>;
  status: "pending";
}

export type InsertResult = "ok" | "slot_taken" | "error";

/** Map the booking form fields to the snake_case PostgREST insert payload. */
export function buildBookingPayload({
  eventTypeId,
  startISO,
  endISO,
  name,
  email,
  answers,
}: BuildPayloadArgs): BookingPayload {
  return {
    event_type_id: eventTypeId,
    start_utc: startISO,
    end_utc: endISO,
    booker_name: name,
    booker_email: email,
    answers,
    status: "pending",
  };
}

/** Postgres SQLSTATE for exclusion_violation (the no-overlap constraint). */
const EXCLUSION_VIOLATION_CODE = "23P01";
const NO_OVERLAP_CONSTRAINT = "booking_requests_no_overlap";

/**
 * Detect the two-people-same-slot race in the PostgREST error body. Against the
 * live stack this surfaces as HTTP 400 (not 409) with Postgres code `23P01`
 * (exclusion_violation) from the `booking_requests_no_overlap` constraint. The
 * body may arrive as a parsed object or as a raw JSON string, so handle both.
 */
function bodyIndicatesSlotTaken(body: unknown): boolean {
  if (body && typeof body === "object") {
    const code = (body as { code?: unknown }).code;
    if (code === EXCLUSION_VIOLATION_CODE) return true;
  }
  if (typeof body === "string") {
    return (
      body.includes(EXCLUSION_VIOLATION_CODE) ||
      body.includes(NO_OVERLAP_CONSTRAINT)
    );
  }
  return false;
}

/**
 * Classify the PostgREST insert response. 201 (and 200/204) = inserted; a
 * Postgres exclusion-violation in the body (`23P01` / `booking_requests_no_overlap`)
 * means someone beat us to the slot — this is the primary signal and arrives as
 * HTTP 400, not 409. 409 is kept as a belt-and-braces fallback for PostgREST
 * versions/configs that return it. Anything else is an unexpected error.
 */
export function classifyInsertResult(
  httpStatus: number,
  body: unknown
): InsertResult {
  if (httpStatus === 200 || httpStatus === 201 || httpStatus === 204) {
    return "ok";
  }
  if (bodyIndicatesSlotTaken(body)) return "slot_taken";
  if (httpStatus === 409) return "slot_taken";
  return "error";
}

/** POST a booking request to PostgREST and return the classified result. */
export async function createBooking(
  payload: BookingPayload
): Promise<InsertResult> {
  const res = await fetch(`${REST_BASE}/booking_requests`, {
    method: "POST",
    headers: {
      ...anonHeaders(),
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify(payload),
  });

  // Success uses `Prefer: return=minimal` (empty body), but FAILURES return the
  // JSON error body — that's where the `23P01` slot-taken signal lives. Parse
  // defensively: try JSON, fall back to the raw text.
  const text = await res.text().catch(() => "");
  let body: unknown = text;
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }
  return classifyInsertResult(res.status, body);
}
