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
  it("returns slot_taken for 409", () => {
    expect(classifyInsertResult(409, "exclusion constraint")).toBe("slot_taken");
  });
  it("returns error for anything else", () => {
    expect(classifyInsertResult(400, "bad")).toBe("error");
    expect(classifyInsertResult(500, "boom")).toBe("error");
    expect(classifyInsertResult(401, "no")).toBe("error");
  });
});
