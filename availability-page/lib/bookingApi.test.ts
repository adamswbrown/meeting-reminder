import { describe, expect, it } from "vitest";
import { buildBookingPayload, classifyInsertResult } from "./bookingApi";

describe("buildBookingPayload", () => {
  it("produces snake_case keys with status pending", () => {
    const payload = buildBookingPayload({
      eventTypeId: "et-1",
      startISO: "2026-06-22T08:00:00.000Z",
      endISO: "2026-06-22T08:30:00.000Z",
      name: "Ada Lovelace",
      email: "ada@example.com",
      answers: { topic: "Analytical engine" },
    });
    expect(payload).toEqual({
      event_type_id: "et-1",
      start_utc: "2026-06-22T08:00:00.000Z",
      end_utc: "2026-06-22T08:30:00.000Z",
      booker_name: "Ada Lovelace",
      booker_email: "ada@example.com",
      answers: { topic: "Analytical engine" },
      status: "pending",
    });
  });
});

describe("classifyInsertResult", () => {
  it("returns ok for 201", () => {
    expect(classifyInsertResult(201, "")).toBe("ok");
  });

  it("returns slot_taken for a 400 with Postgres code 23P01 (parsed object body)", () => {
    // Real PostgREST response when the exclusion constraint rejects an
    // overlapping booking: HTTP 400, NOT 409.
    expect(
      classifyInsertResult(400, {
        code: "23P01",
        details: "Key conflicts with existing key.",
        hint: null,
        message:
          'conflicting key value violates exclusion constraint "booking_requests_no_overlap"',
      })
    ).toBe("slot_taken");
  });

  it("returns slot_taken for a 400 with a string body containing 23P01", () => {
    expect(
      classifyInsertResult(
        400,
        '{"code":"23P01","message":"conflicting key value violates exclusion constraint \\"booking_requests_no_overlap\\""}'
      )
    ).toBe("slot_taken");
  });

  it("returns slot_taken for a string body naming the no-overlap constraint", () => {
    expect(
      classifyInsertResult(400, "...exclusion constraint booking_requests_no_overlap...")
    ).toBe("slot_taken");
  });

  it("returns slot_taken for 409 as a belt-and-braces fallback", () => {
    expect(classifyInsertResult(409, "exclusion constraint")).toBe("slot_taken");
  });

  it("returns error for an unrelated Postgres error (e.g. 23502 not-null)", () => {
    expect(
      classifyInsertResult(400, {
        code: "23502",
        message: 'null value in column "booker_email" violates not-null constraint',
      })
    ).toBe("error");
  });

  it("returns error for anything else", () => {
    expect(classifyInsertResult(400, "bad")).toBe("error");
    expect(classifyInsertResult(500, "boom")).toBe("error");
    expect(classifyInsertResult(401, "no")).toBe("error");
  });
});
