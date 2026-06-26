# Self-Service Booking

A **Cal.com-style booking flow** — visitors pick a slot, it lands on Adam's
Exchange calendar, and they get a confirmation email + `.ics` from
`adam.brown@altra.cloud`. Built entirely on infrastructure this project already
ships: the **same Supabase project** as the availability page, the **Mac app's**
EventKit write access, and **Microsoft Graph** for sending from the Exchange
account (with **Mail.app** as a fallback). No Cal.com, no admin, no paid email
service.

> **Email sending (updated 2026-06-26).** Confirmation/rejection emails now send
> from `adam.brown@altra.cloud` via **Microsoft Graph** (`GraphMailService` →
> `POST /me/sendMail`), authenticated with the **OAuth device-code flow** —
> delegated `Mail.Send`, no admin, no app registration (piggybacks on the public
> "Graph Command Line Tools" client). The refresh token lives in the Keychain
> (`msGraphRefreshToken`); connect once via **Settings → Availability → "Exchange
> sending" → Connect**. Graph needs no local app and works while the Mac is
> awake. If a Graph send fails, the app **falls back to Mail.app** — whose
> AppleScript asserts the Exchange account is enabled and **errors rather than
> sending from any other account (e.g. iCloud)**. A dead/expired Graph sign-in
> surfaces a macOS notification prompting reconnect. The older "Mail.app-only"
> details below describe the fallback path.

```
                    ┌─────────── Supabase (Postgres) ───────────┐
                    │  booking_event_types  (your bookable links)│
                    │  booking_requests     (pending→confirmed)  │
                    │  public_booked_slots  (sanitised view)     │
                    └────────────────────────────────────────────┘
   read slots ▲          ▲ insert intent          ▲ poll + resolve
   (anon key) │          │ (anon key)             │ (service-role key)
              │          │                         │
        ┌─────┴──────────┴─────┐         ┌─────────┴───────────┐
        │  Next.js booking page│         │      Mac app        │
        │  (availability-page/)│         │  (BookingPollService│
        └──────────────────────┘         │  EventKit + Mail.app)│
                                         └─────────────────────┘
```

## Two halves, one loop

The web page never touches the calendar — it only writes **intent** to Supabase.
The Mac app is the single write-back actor that turns intent into a real event.

| Half | Where | What it does |
|------|-------|--------------|
| **Web (intent)** | `availability-page/` — `lib/eventTypes.ts`, `lib/bookingSlots.ts`, `lib/bookingApi.ts`, `app/book/[slug]/page.tsx`, `components/BookingForm.tsx` | Reads event types + free/busy + already-booked slots, generates slots, `INSERT`s a `pending` row via the anon key |
| **Mac (confirm)** | `MeetingReminder/Services/BookingPollService.swift` + `BookingSupport.swift` | Polls `booking_requests` for `status=pending`, checks live EventKit, creates the `EKEvent`, flips the row to `confirmed`, sends a confirmation email + `.ics` |

**The loop:**
1. Visitor opens `/book/<slug>`, sees real open slots for the chosen event type.
2. Submits → a `pending` row is inserted into `booking_requests`. The page shows
   *"Requested — confirmation email shortly."* instantly.
3. The Mac app's poll loop (every 60s while awake) picks up the `pending` row,
   checks **live EventKit** for a conflict (with the event type's buffers):
   - **clear** → creates the `EKEvent` on the Exchange default calendar, PATCHes
     the row to `confirmed` with the `ek_event_id`, then emails the confirmation
     + `.ics` from `adam.brown@altra.cloud`.
   - **conflict** → PATCHes the row to `rejected` and emails a polite rebook note.
4. The next availability push reflects the new event back, so the slot disappears
   for everyone.

---

## 1. Supabase schema

The booking feature lives in the **same Supabase project** as the availability
page (`supabaseProjectURL`). It adds two tables and one sanitised view alongside
the existing `calendar_events` / `public_freebusy`.

> The generic names `event_types` / `bookings` from the original design docs were
> renamed to a **`booking_` prefix** to avoid collisions in the shared Supabase
> project that also hosts other apps. Use the prefixed names everywhere.

### `booking_event_types` — your bookable links

```sql
create table public.booking_event_types (
  id              uuid primary key default gen_random_uuid(),
  slug            text unique not null,         -- "intro-30" → /book/intro-30
  title           text not null,                -- "30-min intro"
  description     text,
  duration_min    int  not null,                -- 15 / 30 / 60
  buffer_before   int  default 0,               -- minutes of guard time before
  buffer_after    int  default 10,              -- minutes of guard time after
  min_notice_min  int  default 120,             -- no bookings inside this window
  max_per_day     int,                          -- null = unlimited
  -- weekly bookable hours, in Europe/London:
  -- {"mon":[["09:00","12:00"],["14:00","17:00"]], ...}
  hours           jsonb not null,
  questions       jsonb default '[]',           -- extra form fields
  active          boolean default true,
  created_at      timestamptz default now()
);
alter table public.booking_event_types enable row level security;
create policy anon_read_event_types on public.booking_event_types
  for select to anon using (active);
```

### `booking_requests` — booking intents (page writes, Mac app resolves)

```sql
create extension if not exists btree_gist;
create table public.booking_requests (
  id            uuid primary key default gen_random_uuid(),
  event_type_id uuid references booking_event_types(id),
  start_utc     timestamptz not null,
  end_utc       timestamptz not null,
  status        text not null default 'pending', -- pending|confirmed|rejected|cancelled
  booker_name   text not null,
  booker_email  text not null,
  answers       jsonb default '{}',
  ek_event_id   text,             -- set by the Mac app when it creates the event
  reject_reason text,
  created_at    timestamptz default now(),
  resolved_at   timestamptz
);

-- No two live bookings can overlap in time (kills the concurrent-insert race).
alter table public.booking_requests add constraint booking_requests_no_overlap
  exclude using gist (tstzrange(start_utc, end_utc) with &&)
  where (status in ('pending','confirmed'));

alter table public.booking_requests enable row level security;
-- anon may INSERT a pending row only; there is deliberately NO anon SELECT policy,
-- so nobody can scrape who booked or read reject reasons.
create policy anon_insert_booking on public.booking_requests
  for insert to anon with check (status = 'pending');
```

### `public_booked_slots` — sanitised view (times only)

Lets the page grey out already-requested slots *before* the Mac app confirms and
the next free/busy push lands. No names, no emails — just `start_utc, end_utc`.

```sql
create view public.public_booked_slots as
  select start_utc, end_utc from public.booking_requests
  where status in ('pending','confirmed');
grant select on public.public_booked_slots to anon;
```

### Lockdown summary (anon / publishable key)

| Object | anon access |
|--------|-------------|
| `booking_event_types` | `SELECT` where `active` (render links) |
| `booking_requests` | **`INSERT` only** (a `pending` row). No `SELECT`. |
| `public_booked_slots` | `SELECT` (times only) |

The Mac app reads and updates `booking_requests` with the **service-role key**
(already in Keychain as `supabaseServiceRoleKey`), which bypasses RLS. That key
stays on the Mac and never reaches the browser.

> **The overlap constraint surfaces as HTTP 400, not 409.** When a second booker
> races for the same slot, PostgREST returns **HTTP 400** with a body carrying
> Postgres code **`23P01`** (`exclusion_violation`) from the
> `booking_requests_no_overlap` constraint. The web client
> (`lib/bookingApi.ts → classifyInsertResult`) classifies that as `"slot_taken"`
> and shows *"That slot was just taken — pick another."* (409 is kept only as a
> belt-and-braces fallback.)

---

## 2. Seeding / adding event types

There is **no management UI yet** (deliberately deferred). Event types are
managed by hand via SQL in the **Supabase dashboard SQL editor**. The booking
page reads them immediately — no app restart, no migration step.

### Add a new event type

```sql
insert into public.booking_event_types
  (slug, title, description, duration_min, buffer_before, buffer_after,
   min_notice_min, max_per_day, hours)
values
  ('intro-30', '30-min intro', 'A quick intro call.',
   30, 0, 10, 120, null,
   '{"mon":[["09:00","12:00"],["14:00","17:00"]],
     "tue":[["09:00","12:00"],["14:00","17:00"]],
     "wed":[["09:00","12:00"],["14:00","17:00"]],
     "thu":[["09:00","12:00"],["14:00","17:00"]],
     "fri":[["09:00","12:00"]]}');
```

Field reference:

| Column | Meaning |
|--------|---------|
| `slug` | URL segment — booking link is `/book/<slug>` |
| `title` | Shown as the page heading and in the calendar event title |
| `duration_min` | Slot length in minutes (e.g. 15 / 30 / 60) |
| `buffer_before` / `buffer_after` | Guard minutes the slot generator keeps clear around the meeting; also applied to the Mac app's live conflict check |
| `min_notice_min` | Earliest a slot may start, relative to now (e.g. 120 = no bookings inside 2h) |
| `max_per_day` | Cap on bookings per owner-day; `null` = unlimited |
| `hours` | Weekly bookable hours (see below) |
| `questions` | Optional extra form fields, JSON array of `{id, label, required}` |
| `active` | `false` hides the type and 404s its `/book/<slug>` link |

### The `hours` jsonb shape

A map of **weekday → list of `["HH:mm","HH:mm"]` ranges**, all in
**Europe/London** (the owner timezone used throughout the app). Omit a weekday to
make it unbookable. Each range is an open window the slot generator slices into
steps of `duration_min + buffer_after`:

```json
{
  "mon": [["09:00","12:00"], ["14:00","17:00"]],
  "tue": [["09:00","12:00"], ["14:00","17:00"]],
  "wed": [["09:00","12:00"], ["14:00","17:00"]],
  "thu": [["09:00","12:00"], ["14:00","17:00"]],
  "fri": [["09:00","12:00"]]
}
```

Weekday keys: `mon tue wed thu fri sat sun`.

### Seeded types

| Slug | Duration | Link |
|------|----------|------|
| `intro-30` | 30 min | `/book/intro-30` |
| `deep-60` | 60 min | `/book/deep-60` |

---

## 3. Enable on the Mac

The confirmation half runs in the Mac app's `BookingPollService`, which **reuses
the same Supabase URL + service-role key** as the availability push. So the
availability push must already be configured (Settings → Availability tab) — the
booking loop has no separate credentials.

1. **Settings → Availability tab.** Confirm the **Supabase project URL** and
   **service-role key** are set (these are the availability-push credentials; the
   key lives in Keychain as `supabaseServiceRoleKey`).
2. Toggle **Enable booking confirmations** on (this sets `bookingPollEnabled`).
   The poll loop starts immediately and fires once for instant feedback.
3. **Grant the one-time Mail Automation permission.** The first confirmation send
   triggers a macOS prompt — *"MeetingReminder wants to control Mail."* Click
   **OK**. The app is non-sandboxed, so this is allowed; if you deny it, emails
   won't send (the booking still confirms — the event exists either way). You can
   re-grant it later in **System Settings → Privacy & Security → Automation**.

The poll loop runs every **60s while the Mac is awake**. The Settings status line
shows the last poll time and a one-line result (e.g. `confirmed=1 rejected=0
failed=0`).

---

## 4. Booking links to share

```
https://<your-vercel-domain>/book/intro-30
https://<your-vercel-domain>/book/deep-60
```

One link per event type — the slug must match a row in `booking_event_types`
with `active = true`. An inactive or unknown slug shows a friendly "link isn't
available" page.

---

## 5. Double-booking protection & timing

Two distinct races are covered:

- **Race 1 — two bookers, same slot, same moment.** Killed at the database by the
  `booking_requests_no_overlap` GiST exclusion constraint, which atomically
  rejects the second concurrent `pending`/`confirmed` insert. The loser's page
  shows "just taken, pick another" (the HTTP 400 / `23P01` path above).
- **Race 2 — stale availability.** A visitor sees a slot free that Adam just
  filled manually in Outlook before the next free/busy push. Caught at
  confirmation: the Mac app checks **live EventKit** (buffered by the event
  type's `buffer_before`/`buffer_after`) before committing, and rejects with a
  rebook email if there's a real conflict.

The `min_notice_min` knob shrinks Race 2 further — a slot must survive a couple of
push cycles before it's bookable.

**Two-phase confirmation timing.** Submitting is instant ("Requested…"); the
real confirmation lands **within ~a minute** while the Mac is awake. Honest, and
Cal.com isn't truly instant either.

**Idempotency.** Each created event is tagged with `[booking-id:<id>]` in its
notes. If a poll creates the event but dies before the `confirmed` PATCH lands,
the next pass finds the tagged event and re-confirms it instead of duplicating or
false-rejecting. The conflict check also excludes the booking's own event (by
`ek_event_id` or by the marker), so a re-poll never sees its own event as a
conflict.

---

## Limitations (v1)

- **The Mac must be awake** for a booking to confirm. While it's asleep/off,
  bookings sit `pending` and confirm when it next wakes (within ~a minute).
- **No self-service reschedule / cancel** for the booker yet (planned follow-up;
  cancel = flip status + delete the `EKEvent` + notify).
- **No Exchange attendee accept/decline tracking** — that needs Microsoft Graph,
  which isn't available here. The `.ics` invite is the substitute: it lands in
  the booker's calendar with `METHOD:REQUEST` so they can accept it locally.
- **No event-type management UI** — types are managed via SQL / the Supabase
  dashboard (see §2).

---

## Troubleshooting

**Confirmations not arriving / bookings stuck `pending`:**

1. **Check the Settings status line** (Availability tab) — does it show a recent
   poll time and a result? `failed=N` points at a Console-logged error.
2. **`bookingPollEnabled` is on** — re-toggle "Enable booking confirmations".
3. **Mail Automation permission granted** — System Settings → Privacy & Security
   → Automation → MeetingReminder → Mail must be ticked. If the calendar event
   appears but no email arrives, this is the usual cause (the booking still
   confirms; only the email failed — see the Console log).
4. **The Mac is awake** — the loop doesn't run while asleep.
5. **Supabase credentials present** — the status line shows "Not configured" if
   the project URL or service-role key is missing; re-enter them in the
   Availability tab.

**Web page says "That slot was just taken":** expected — the overlap constraint
fired (HTTP 400 / `23P01`). Someone booked that slot first; pick another.

**Page shows no slots:** the event type's `hours` may not cover upcoming
weekdays, `min_notice_min` may be filtering everything out, or owner free/busy
covers the window. Check the seeded `hours` and that the availability push is
running.
