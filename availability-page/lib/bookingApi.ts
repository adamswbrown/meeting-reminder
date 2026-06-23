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

/**
 * Classify the PostgREST insert response. 201 = inserted; 409 = the Postgres
 * exclusion constraint rejected an overlapping slot (someone beat us to it);
 * anything else is an unexpected error.
 */
export function classifyInsertResult(
  httpStatus: number,
  body: string
): InsertResult {
  void body; // classification is status-driven; body kept for caller symmetry/logging
  if (httpStatus === 201) return "ok";
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

  const body = await res.text().catch(() => "");
  return classifyInsertResult(res.status, body);
}
