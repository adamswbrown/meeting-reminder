# Self-Hosted Booking Implementation Plan

> **Update (2026-06-23):** The deployed Supabase table names are
> **`booking_event_types`** and **`booking_requests`** (the generic `event_types`
> / `bookings` names below were prefixed with `booking_` to avoid collisions in
> the shared Supabase project). The overlap-constraint violation surfaces as
> **HTTP 400 with Postgres code `23P01`**, not 409. The rest of this doc is kept
> as historical record. See [../BOOKING.md](../BOOKING.md) for the live schema.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add real self-service booking (Cal.com-style) — visitors pick an event-type slot, it lands on Adam's Exchange calendar and they get a confirmation email + `.ics` from `adam.brown@altra.cloud` — reusing the existing Supabase + Mac-app + Mail.app infrastructure, with no Graph, no OAuth, no paid email service.

**Architecture:** Supabase is the coordination layer (`event_types`, `bookings` tables + sanitised views). The Next.js page in `availability-page/` reads event types + free/busy + already-booked slots, generates slots, and `INSERT`s a `pending` booking via the anon key. The Mac app's new `BookingPollService` polls pending rows, checks live EventKit for conflicts, creates the `EKEvent`, sends a confirmation `.ics` email via Mail.app/AppleScript, and flips the booking to `confirmed`/`rejected`. Two-phase confirm + a Postgres exclusion constraint kill both double-booking races.

**Tech Stack:** Supabase (Postgres/PostgREST), Swift/EventKit/Combine + `osascript` (Mac app), Next.js 16 / React 19 / TypeScript (web). Swift tests: XCTest (`MeetingReminderTests`). Web tests: Vitest (added in Task C0).

**Companion design doc:** `docs/plans/2026-06-23-self-hosted-booking-design.md` — read it first for the rationale and decision log.

**Pre-existing scaffolding to reuse / not duplicate:**
- `availability-page/lib/availability.ts` — slot generation from free/busy (adapt for per-event-type rules).
- `availability-page/lib/supabase.ts` — anon PostgREST GET helper (`rest<T>`), `fetchFreeBusy()`.
- `availability-page/lib/booking.ts` + `components/SlotActionsDialog.tsx` — the **propose-via-link** model. Leave intact; the new real-booking flow lives at `/book/[slug]` and does not replace the homepage.
- `MeetingReminder/Services/AvailabilityPushService.swift` — copy its timer + `authedRequest`/`send` HTTP pattern and Keychain key (`supabaseServiceRoleKey`).

**Conventions:**
- All owner-side times are **Europe/London**.
- Commit after every passing step. Push only when Adam asks.
- Manual pbxproj edits MUST use globally-unique object IDs (see CLAUDE.md "Releasing & CI").

---

## Phase A — Supabase schema (foundation)

No automated tests; verification is via SQL queries / PostgREST curl. Apply via the Supabase MCP `apply_migration` tool or the dashboard SQL editor.

### Task A1: Create `event_types` table

**Step 1: Apply migration**
```sql
create table public.event_types (
  id              uuid primary key default gen_random_uuid(),
  slug            text unique not null,
  title           text not null,
  description     text,
  duration_min    int  not null,
  buffer_before   int  default 0,
  buffer_after    int  default 10,
  min_notice_min  int  default 120,
  max_per_day     int,
  hours           jsonb not null,   -- {"mon":[["09:00","12:00"],["14:00","17:00"]],...}
  questions       jsonb default '[]',
  active          boolean default true,
  created_at      timestamptz default now()
);
alter table public.event_types enable row level security;
create policy anon_read_event_types on public.event_types
  for select to anon using (active);
```

**Step 2: Verify** — `select * from event_types;` returns 0 rows, no error. Confirm RLS is on: `select relrowsecurity from pg_class where relname='event_types';` → `t`.

### Task A2: Create `bookings` table + overlap constraint

**Step 1: Apply migration**
```sql
create extension if not exists btree_gist;
create table public.bookings (
  id            uuid primary key default gen_random_uuid(),
  event_type_id uuid references event_types(id),
  start_utc     timestamptz not null,
  end_utc       timestamptz not null,
  status        text not null default 'pending',  -- pending|confirmed|rejected|cancelled
  booker_name   text not null,
  booker_email  text not null,
  answers       jsonb default '{}',
  ek_event_id   text,
  reject_reason text,
  created_at    timestamptz default now(),
  resolved_at   timestamptz
);
alter table public.bookings add constraint no_overlap
  exclude using gist (tstzrange(start_utc, end_utc) with &&)
  where (status in ('pending','confirmed'));
alter table public.bookings enable row level security;
create policy anon_insert_booking on public.bookings
  for insert to anon with check (status = 'pending');
-- NOTE: deliberately NO anon select policy → anon cannot read bookings.
```

**Step 2: Verify the constraint works**
```sql
insert into bookings (start_utc,end_utc,booker_name,booker_email)
  values ('2099-01-01T10:00Z','2099-01-01T10:30Z','t','t@t');
-- second overlapping insert MUST fail with exclusion violation:
insert into bookings (start_utc,end_utc,booker_name,booker_email)
  values ('2099-01-01T10:15Z','2099-01-01T10:45Z','t','t@t');
delete from bookings where booker_email='t@t';
```
Expected: first succeeds, second errors `conflicting key value violates exclusion constraint "no_overlap"`.

### Task A3: Sanitised `public_booked_slots` view

**Step 1: Apply migration**
```sql
create view public.public_booked_slots as
  select start_utc, end_utc from bookings
  where status in ('pending','confirmed');
grant select on public.public_booked_slots to anon;
```

**Step 2: Verify** anon can read times only — curl PostgREST with the anon key:
```
GET /rest/v1/public_booked_slots?select=start_utc,end_utc
```
Expected: 200, array of `{start_utc,end_utc}`. Confirm `GET /rest/v1/bookings?select=*` with anon key returns `[]`/permission error (no anon select).

### Task A4: Seed event types

**Step 1: Insert 2 event types**
```sql
insert into event_types (slug,title,description,duration_min,buffer_after,min_notice_min,hours) values
('intro-30','30-min intro','A quick intro call.',30,10,120,
  '{"mon":[["09:00","12:00"],["14:00","17:00"]],"tue":[["09:00","12:00"],["14:00","17:00"]],"wed":[["09:00","12:00"],["14:00","17:00"]],"thu":[["09:00","12:00"],["14:00","17:00"]],"fri":[["09:00","12:00"]]}'),
('deep-60','60-min deep dive','A longer working session.',60,15,240,
  '{"tue":[["10:00","12:00"]],"thu":[["10:00","12:00"]]}');
```

**Step 2: Verify** `select slug,title,duration_min from event_types order by slug;` → 2 rows.

**Step 3: Commit** the SQL files (if migrations were saved locally under `availability-page/supabase/` or `docs/`).
```bash
git add docs/plans/2026-06-23-self-hosted-booking-*.md
git commit -m "feat(booking): supabase schema for self-service booking"
```

---

## Phase B — Mac app write-back (`BookingPollService`)

TDD the **pure** logic in `MeetingReminderTests` (XCTest). EventKit event creation, URLSession calls, and the live `osascript` send are verified manually (they need a real calendar/Mail.app and can't be unit-tested cleanly). Isolate everything testable into `BookingSupport.swift` so the untestable surface is tiny.

Reference @superpowers:test-driven-development for the RED-GREEN-REFACTOR discipline.

### Task B1: Booking model + decode (pure)

**Files:**
- Create: `MeetingReminder/Services/BookingSupport.swift`
- Test: `MeetingReminderTests/BookingSupportTests.swift`

**Step 1: Write the failing test**
```swift
import XCTest
@testable import MeetingReminder

final class BookingSupportTests: XCTestCase {
    func testDecodePendingBooking() throws {
        let json = """
        [{"id":"abc","start_utc":"2026-07-01T10:00:00+00:00","end_utc":"2026-07-01T10:30:00+00:00",
          "status":"pending","booker_name":"Sam","booker_email":"sam@example.com",
          "answers":{},"event_type_id":"et1","ek_event_id":null}]
        """.data(using: .utf8)!
        let rows = try PendingBooking.decodeList(json)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bookerName, "Sam")
        XCTAssertEqual(rows[0].id, "abc")
        XCTAssertNil(rows[0].ekEventID)
    }
}
```

**Step 2: Run, expect FAIL** — `xcodebuild test -project MeetingReminder.xcodeproj -scheme MeetingReminder -only-testing:MeetingReminderTests/BookingSupportTests` → "cannot find PendingBooking".

**Step 3: Minimal implementation** in `BookingSupport.swift`
```swift
import Foundation

struct PendingBooking: Decodable {
    let id: String
    let startUTC: Date
    let endUTC: Date
    let status: String
    let bookerName: String
    let bookerEmail: String
    let eventTypeID: String?
    let ekEventID: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case startUTC = "start_utc"
        case endUTC = "end_utc"
        case bookerName = "booker_name"
        case bookerEmail = "booker_email"
        case eventTypeID = "event_type_id"
        case ekEventID = "ek_event_id"
    }

    static func decodeList(_ data: Data) throws -> [PendingBooking] {
        let dec = JSONDecoder()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fNoFrac = ISO8601DateFormatter(); fNoFrac.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = f.date(from: s) ?? fNoFrac.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad date \(s)"))
        }
        return try dec.decode([PendingBooking].self, from: data)
    }
}
```

**Step 4: Run, expect PASS.**

**Step 5: Wire the two new files into pbxproj** (unique IDs — mirror an existing file's 4 entries: PBXBuildFile, PBXFileReference, group children, Sources phase). Add `BookingSupport.swift` to the app target and `BookingSupportTests.swift` to `MeetingReminderTests`. Re-run the test to confirm it compiles in-project.

**Step 6: Commit** `git commit -am "feat(booking): PendingBooking decode + test"`

### Task B2: Conflict-overlap helper (pure)

**Step 1: Failing test** (append to `BookingSupportTests`)
```swift
func testOverlapDetection() {
    let s = ISO8601DateFormatter()
    let r = DateInterval(start: s.date(from:"2026-07-01T10:00:00Z")!, end: s.date(from:"2026-07-01T11:00:00Z")!)
    // existing event 10:30–10:45 overlaps
    XCTAssertTrue(BookingConflict.overlaps(range: r,
        events: [(s.date(from:"2026-07-01T10:30:00Z")!, s.date(from:"2026-07-01T10:45:00Z")!)]))
    // existing event 11:00–12:00 is adjacent, no overlap
    XCTAssertFalse(BookingConflict.overlaps(range: r,
        events: [(s.date(from:"2026-07-01T11:00:00Z")!, s.date(from:"2026-07-01T12:00:00Z")!)]))
}
func testOverlapIgnoresOwnEvent() {
    // an event whose identifier matches the booking's ek_event_id is excluded by the caller,
    // so overlaps() only ever sees foreign events — documented contract, asserted in B5 manual test.
}
```

**Step 2–4:** implement `BookingConflict.overlaps(range:events:)` using `DateInterval.intersects`, run RED→GREEN.

**Step 5: Commit.**

### Task B3: `.ics` builder (pure)

**Step 1: Failing test** — assert the produced string contains `BEGIN:VEVENT`, correct `DTSTART`/`DTEND` in `YYYYMMDDTHHMMSSZ`, `SUMMARY`, CRLF line endings, and RFC-5545 escaping of commas in the description. (Mirror the existing web `buildICSContent` format in `availability-page/lib/booking.ts` for consistency.)

**Step 2–4:** implement `BookingICS.build(title:start:end:organizerEmail:attendeeEmail:description:)` returning a CRLF-joined VCALENDAR with `METHOD:REQUEST`, `ORGANIZER`, and an `ATTENDEE` line. RED→GREEN.

**Step 5: Commit.**

### Task B4: AppleScript composer string (pure)

**Step 1: Failing test** — `MailAppleScript.compose(account:to:subject:body:icsPath:)` returns a script string that contains the pinned sender (`set sender to "...altra.cloud..."`), the recipient `make new to recipient`, the attachment line referencing `icsPath`, and `visible:false`. Assert quotes in subject/body are escaped so the script can't break.

**Step 2–4:** implement, RED→GREEN.

**Step 5: Commit.**

### Task B5: `BookingPollService` orchestration (manual-verified)

**Files:**
- Create: `MeetingReminder/Services/BookingPollService.swift`
- Modify: `MeetingReminder/MeetingReminderApp.swift` (instantiate in `OverlayCoordinator`/app launch, like `AvailabilityPushService`)

**Step 1: Implement** an `@MainActor final class BookingPollService: ObservableObject` that:
- Reuses `supabaseProjectURL` + `supabaseServiceRoleKey` (copy `authedRequest`/`send` from `AvailabilityPushService.swift:306-318`).
- `Timer` every 60s (guarded by an `isEnabled` AppStorage key `bookingPollEnabled`, default false).
- `pollOnce()`:
  1. `GET /rest/v1/bookings?status=eq.pending&select=...` → `PendingBooking.decodeList`.
  2. For each: query EventKit `events(matching:)` over enabled calendars in `[start-bufferBefore, end+bufferAfter]`; map to `(start,end)` tuples **excluding** any event whose `eventIdentifier == booking.ekEventID`; call `BookingConflict.overlaps`.
  3. Conflict → `PATCH .../bookings?id=eq.<id>` set `status='rejected', reject_reason, resolved_at=now()`; send "rebook" email.
  4. Clear → create `EKEvent` (title from event type + booker name; notes = answers + booker email), `save`, capture `eventIdentifier`; `PATCH` set `status='confirmed', ek_event_id, resolved_at`; build `.ics` (B3) to a temp file; run `MailAppleScript` (B4) via `Process`/`osascript` (mirror the busy-light shell-out).
- **Idempotency:** only flip to `confirmed` AFTER the EKEvent saved and `ek_event_id` PATCHed; the B2 `ekEventID` exclusion stops a re-poll seeing its own event.

**Step 2: Build** `xcodebuild ... build`. Wire new file into pbxproj (unique IDs).

**Step 3: Manual verification (the real test)**
1. Set `bookingPollEnabled` true; ensure Supabase URL + service key configured.
2. Insert a `pending` booking via SQL for a free slot ~5 min out.
3. Within ~60s: confirm an event appears in Apple Calendar, the booking row flips to `confirmed` with `ek_event_id` set, and a confirmation email arrives at the test address from `adam.brown@altra.cloud` with the `.ics` attached.
4. Insert a `pending` booking that overlaps an existing real event → confirm it flips to `rejected` and the rebook email arrives, and NO calendar event is created.
5. Kill the app mid-poll (Activity Monitor) right after event creation but before — re-launch, confirm no duplicate event/email (idempotency).

**Step 4: Commit** `git commit -am "feat(booking): BookingPollService write-back via EventKit + Mail.app"`

### Task B6: Settings toggle for the poll loop

**Step 1:** Add a control (existing Availability tab or a new row) binding `bookingPollEnabled`, plus a one-line status (last poll time, last result). Mirror `AvailabilityPushService`'s published state.

**Step 2:** Build, deploy (kill/copy/relaunch per CLAUDE.md), confirm toggle starts/stops the timer.

**Step 3: Commit.**

---

## Phase C — Web booking flow (`/book/[slug]`)

Add Vitest for the pure new logic; UI verified manually with `pnpm dev`. Leave the existing homepage propose-via-link flow untouched.

### Task C0: Add Vitest

**Files:**
- Modify: `availability-page/package.json` (add `"test": "vitest run"`, devDeps `vitest`)
- Create: `availability-page/vitest.config.ts`

**Step 1:** Install + minimal config (node environment). **Step 2:** add a trivial passing smoke test, run `pnpm test`, expect PASS. **Step 3: Commit.**

### Task C1: Fetch event types (lib)

**Files:**
- Create: `availability-page/lib/eventTypes.ts`
- Test: `availability-page/lib/eventTypes.test.ts`

**Step 1: Failing test** — `parseEventType(row)` maps the snake_case PostgREST row (incl. `hours` jsonb) to a typed `EventType` (camelCase, `hours` as a weekday→ranges map). Assert duration, bufferAfter, minNoticeMin, and a parsed `hours.mon` range.

**Step 2–4:** implement `parseEventType` + `fetchEventType(slug)` / `fetchActiveEventTypes()` reusing the `rest<T>` pattern from `lib/supabase.ts` (`event_types?slug=eq.<slug>&active=eq.true`). Pure parser is unit-tested; the fetch wrapper is thin. RED→GREEN.

**Step 5: Commit.**

### Task C2: Slot generation per event type (lib)

**Files:**
- Create: `availability-page/lib/bookingSlots.ts`
- Test: `availability-page/lib/bookingSlots.test.ts`

**Step 1: Failing tests** for a pure `generateSlots({eventType, freeBusy, bookedSlots, now})`:
- Slots fall only inside the event type's `hours` for each weekday (Europe/London).
- Slots are spaced by `duration + bufferAfter`.
- A slot overlapping a `freeBusy` block (padded by `bufferBefore`) is excluded.
- A slot overlapping a `bookedSlots` entry is excluded.
- A slot starting before `now + minNoticeMin` is excluded.
- `maxPerDay` caps slots per day.

Reuse the interval-subtraction approach already in `lib/availability.ts` (`subtractBusy`, `discretiseWindow`) rather than reinventing — import/refactor shared helpers if practical.

**Step 2–4:** implement, RED→GREEN for each assertion (commit per green where natural).

**Step 5: Commit.**

### Task C3: Insert-booking client (lib)

**Files:**
- Create: `availability-page/lib/bookingApi.ts`
- Test: `availability-page/lib/bookingApi.test.ts`

**Step 1: Failing test** — `buildBookingPayload({eventTypeId, startISO, endISO, name, email, answers})` returns the exact object POSTed to PostgREST (`status:"pending"`, snake_case keys), and `classifyInsertResult(status, body)` maps HTTP 409 (exclusion violation) → `"slot_taken"`, 201 → `"ok"`, else `"error"`.

**Step 2–4:** implement payload builder + `createBooking()` (POST `bookings` with anon key, `Prefer: return=minimal`). The network call is thin; the pure builder/classifier is tested. RED→GREEN.

**Step 5: Commit.**

### Task C4: Booking route + form (UI, manual-verified)

**Files:**
- Create: `availability-page/app/book/[slug]/page.tsx` (server component: fetch event type + free/busy + booked slots, generate slots, render)
- Create: `availability-page/components/BookingForm.tsx` (client: slot grid → name/email/answers form → `createBooking` → states: idle / submitting / requested / slot_taken / error)

**Step 1: Implement.** On success show "Requested — you'll get a confirmation email shortly." On `slot_taken` show "That slot was just taken — pick another" and refresh slots. Render owner+visitor timezones using existing `lib/format.ts` helpers.

**Step 2: Manual verification** — `pnpm dev`, open `/book/intro-30`:
- Slots match the seeded `intro-30` hours, exclude busy + min-notice.
- Submit a booking → row appears in Supabase as `pending` → (with Phase B running) becomes a real calendar event + email.
- Book the same slot twice quickly → second gets the "just taken" message (409 path).

**Step 3: Commit.**

### Task C5: Link the new flow from the homepage (optional, small)

**Step 1:** Add a "Book a call" section listing active event types (from `fetchActiveEventTypes`) linking to `/book/<slug>`. **Step 2:** Manual check. **Step 3: Commit.**

---

## Phase D — End-to-end & docs

### Task D1: Full E2E dry run
With Phase B poll loop enabled and the page deployed (or `pnpm dev`):
1. Book `intro-30` as a fake visitor → confirm calendar event + email + `.ics` opens correctly in a separate calendar app.
2. Manually fill a slot in Outlook, then book it on the page before the next push → confirm rejection + rebook email (Race 2).
3. Two browsers, same slot, simultaneous submit → one confirmed, one "just taken" (Race 1).
4. Lower push interval / min-notice, retest edge timing.

### Task D2: Docs
- Update `CLAUDE.md`: new `BookingPollService`, `bookingPollEnabled` key, the `bookings`/`event_types` tables, and the Mail.app/AppleScript send.
- Add `docs/BOOKING.md`: schema, seeding event types, the poll loop, and how to grant the one-time Mail Automation permission.
- Commit.

### Task D3: Finish the branch
Use @superpowers:finishing-a-development-branch to decide merge/PR. Remember: push to `mine`, never `origin`.

---

## Out of scope (v1)
Reschedule/cancel self-service links; Settings-tab event-type editor (SQL seed only for now); payments; round-robin/multi-host; booker reminders beyond the `.ics`; Exchange attendee accept/decline tracking (impossible without Graph — the `.ics` substitutes).

## Risk notes
- **Mac-awake dependency:** confirmations only happen while the Mac is awake + Mail.app can run. Accepted trade-off (see design doc).
- **AppleScript/Mail.app brittleness:** keep the script tiny and pure-tested (B4); failures should mark the booking `confirmed` (event exists) but log the email failure, not crash the loop.
- **pbxproj ID collisions:** every new Swift file needs a fresh unique object ID across all 4 entries (CLAUDE.md).
- **`.ics` METHOD:** use `REQUEST` (not `PUBLISH`) so the attendee's calendar treats it as an invite they can accept.
