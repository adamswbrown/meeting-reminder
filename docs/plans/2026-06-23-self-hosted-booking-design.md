# Self-Hosted Booking ("Cal.com replacement") — Design

**Date:** 2026-06-23
**Status:** Design agreed, not yet implemented
**Goal:** Replicate the core Cal.com outcome — let people see Adam's availability
and book his time — using only infrastructure already in this project. No Cal.com,
no Microsoft Graph, no external email service.

---

## Why this is achievable

The project already ships the hard half of "show my availability":
`AvailabilityPushService` pushes a sanitised free/busy snapshot to Supabase, and
the public Next.js page in `availability-page/` reads it. The missing half is
**booking** — letting a visitor pick a slot and have it land on Adam's calendar.

The one genuinely hard piece in any booking system is the **write-back loop**:
something must create the event on the real calendar. Cal.com does this via
OAuth to Google/Microsoft. Adam has **no Graph access** and **cannot send mail
as the corporate domain from a cloud service** (he doesn't control `altra.cloud`
DNS, so SPF/DKIM for an external sender is impossible). The Mac app, however,
**already has EventKit write access and a Mail.app mailbox for the Exchange
account** — so it can both create the event and send a genuine confirmation
email from `adam.brown@altra.cloud`. That makes the Mac app the natural single
write-back actor, reusing everything already built.

### Decisions locked during brainstorming

| Decision | Choice |
|----------|--------|
| Write-back | **Mac app creates the EKEvent** (no OAuth/Graph). Reuses EventKit + Supabase. Accepts the Mac-awake dependency. |
| Configurability | **Multiple event types** (Cal.com-style links), but management UI deferred — see below. |
| Confirmation to booker | **Email + `.ics`**, sent from the real Exchange account via **Mail.app AppleScript** (`osascript`). No Resend/Graph/DNS. |
| Sender identity | Genuinely `adam.brown@altra.cloud` — Exchange itself sends, so SPF/DKIM pass. |
| Double-booking | **Two-phase: `pending` → `confirmed`** with a DB exclusion constraint + live EventKit conflict check. Plus a minimum-notice setting. |
| Event-type management v1 | **SQL seed first** (Supabase dashboard); build a Settings tab as fast-follow. |

---

## Architecture & data flow

One actor stays in charge: the **Mac app**. Supabase is the coordination layer.
No new external services.

```
                    ┌─────────── Supabase (Postgres) ───────────┐
                    │  calendar_events   (free/busy, you push)   │
                    │  event_types       (your bookable links)   │
                    │  bookings          (pending→confirmed)     │
                    └────────────────────────────────────────────┘
   push free/busy ▲          ▲ read slots        ▲ insert booking
   (existing, 2-5m)│         │ (anon key)        │ (anon key)
                   │         │                   │
        ┌──────────┴───┐   ┌─┴───────────────────┴─┐
        │   Mac app    │   │  Next.js booking page  │
        │ (EventKit +  │   │  (availability-page/)  │
        │  Mail.app)   │   └────────────────────────┘
        └──────┬───────┘
   poll bookings│  on pending: check live EventKit →
   (new loop)   │    create EKEvent + send .ics via Mail.app
                ▼    flip confirmed | rejected
```

**Booking flow:**
1. Visitor opens `/book/<slug>` → reads `event_types` + `public_freebusy` +
   `public_booked_slots`, sees real open slots for the chosen type.
2. Submits → row inserted into `bookings` as `pending`. Postgres exclusion
   constraint blocks overlapping concurrent inserts (**Race 1 dead**).
3. Page shows "Requested — confirmation email coming shortly."
4. Mac app's poll loop picks up the `pending` row, checks **live EventKit** for a
   real conflict (**Race 2**):
   - clear → creates EKEvent on Exchange calendar, sends confirmation + `.ics`
     from `adam.brown@altra.cloud` via Mail.app, flips to `confirmed`.
   - conflict → flips to `rejected`, sends "just filled, rebook here."
5. Next free/busy push reflects the new event back, so the slot disappears for
   everyone.

The booking page never touches the calendar directly — it only writes intent to
Supabase.

---

## Data model

Two new tables plus one sanitised view, alongside the existing `calendar_events`.

```sql
-- Your bookable links (you manage these; rarely change)
create table public.event_types (
  id              uuid primary key default gen_random_uuid(),
  slug            text unique not null,         -- "intro-30" → /book/intro-30
  title           text not null,                -- "30-min intro"
  description     text,
  duration_min    int  not null,                -- 15 / 30 / 60
  buffer_before   int  default 0,
  buffer_after    int  default 10,              -- gap after, in minutes
  min_notice_min  int  default 120,             -- no bookings inside 2h
  max_per_day     int,                          -- null = unlimited
  -- weekly bookable hours, in Europe/London, e.g.
  -- {"mon":[["09:00","12:00"],["14:00","17:00"]], ...}
  hours           jsonb not null,
  questions       jsonb default '[]',           -- extra form fields
  active          boolean default true
);

-- Booking intents (the page writes; Mac app resolves)
create table public.bookings (
  id            uuid primary key default gen_random_uuid(),
  event_type_id uuid references event_types(id),
  start_utc     timestamptz not null,
  end_utc       timestamptz not null,
  status        text not null default 'pending', -- pending|confirmed|rejected|cancelled
  booker_name   text not null,
  booker_email  text not null,
  answers       jsonb default '{}',
  ek_event_id   text,            -- set by Mac app when it creates the event
  reject_reason text,
  created_at    timestamptz default now(),
  resolved_at   timestamptz
);

-- Race 1 killer: no two live bookings can overlap in time.
create extension if not exists btree_gist;
alter table public.bookings add constraint no_overlap
  exclude using gist (tstzrange(start_utc, end_utc) with &&)
  where (status in ('pending','confirmed'));

-- Sanitised: lets the page grey out already-requested slots BEFORE the
-- Mac app confirms + the next free/busy push lands. Times only, no names.
create view public.public_booked_slots as
  select start_utc, end_utc from bookings
  where status in ('pending','confirmed');
```

**Lockdown (anon / publishable key):**
- `event_types`: anon `SELECT` where `active` — to render links.
- `bookings`: anon **`INSERT` only** (a `pending` row). Anon **cannot `SELECT`**
  bookings — nobody can scrape who booked or reject reasons.
- `public_booked_slots`: anon `SELECT` — times only.
- `calendar_events`: unchanged — anon reads only `public_freebusy`.
- Mac app reads/updates `bookings` with the **service-role key** (already in
  Keychain as `supabaseServiceRoleKey`).

```sql
alter table public.bookings    enable row level security;
alter table public.event_types enable row level security;
-- anon: insert bookings, select active event_types, select booked slots
create policy anon_insert_booking on public.bookings
  for insert to anon with check (status = 'pending');
create policy anon_read_event_types on public.event_types
  for select to anon using (active);
grant select on public.public_booked_slots to anon;
grant select on public.public_freebusy     to anon;
```

---

## Slot generation (page, stateless)

Run per event type when `/book/<slug>` opens, for the next ~14 days, entirely
from anon-readable data:

1. **Generate candidates.** For each day, take the event type's `hours` for that
   weekday (in **Europe/London**, consistent with the rest of the app). Slice
   into steps of `duration_min + buffer_after`.
2. **Subtract real busy time.** Drop candidates overlapping any `public_freebusy`
   block (padded by `buffer_before`).
3. **Subtract already-booked.** Drop candidates overlapping `public_booked_slots`.
4. **Apply min-notice.** Drop anything starting sooner than `min_notice_min`.
5. **Apply max-per-day.** Hide remaining slots on days already at `max_per_day`.
6. **Render in the visitor's timezone**, labelled with Adam's TZ too
   ("2:00 PM GMT").

Pure, recomputed every load — no precomputed slot table to keep fresh. The only
truth-lag is the free/busy push interval, which the two-phase confirm covers.

---

## Double-booking protection

Two distinct races:

- **Race 1 — two bookers, same slot, same moment.** Solved at the database: the
  `no_overlap` exclusion constraint atomically rejects the second concurrent
  `pending`/`confirmed` insert. The loser sees "just taken, pick another."
- **Race 2 — stale availability.** Visitor sees a slot free that Adam just filled
  manually in Outlook before the next push. Solved at confirmation: the Mac app
  checks **live EventKit** before committing, and rejects (with a polite rebook
  email) if there's a real conflict.

Two knobs shrink Race 2 to near-zero: **minimum notice** (a slot must survive a
couple of push cycles before it's bookable) and a **shorter push interval** while
this matters.

**Trade-off accepted:** confirmation is "within a minute or two," not instant.
Honest, and Cal.com isn't truly instant either.

---

## Mac app side — `BookingPollService.swift`

A new service mirroring `AvailabilityPushService` (same timer pattern, same
Supabase URL, **reuses** `supabaseServiceRoleKey` from Keychain). Wired into
`OverlayCoordinator` / app launch like the other services.

**Poll loop (~60s while awake):**
```
1. GET bookings where status = 'pending'   (service-role key)
2. For each pending booking:
   a. Conflict check — query live EventKit across enabled calendars:
        eventStore.events(matching: predicate(start−bufferBefore … end+bufferAfter))
      Guard against counting this booking's own already-created event via ek_event_id.
   b. If a real event overlaps → REJECT:
        PATCH status='rejected', reject_reason, resolved_at=now
        send "just filled, rebook" email via Mail.app
   c. Else → CONFIRM:
        - create EKEvent (title from event_type + booker name,
          notes = answers + booker email)
        - save to EventKit, capture eventIdentifier
        - PATCH status='confirmed', ek_event_id, resolved_at=now
        - send confirmation + .ics via Mail.app
3. Next availability push reflects the new event → slot vanishes everywhere.
```

**Idempotency / crash-safety.** A booking only flips to `confirmed` *after* the
EKEvent is saved and `ek_event_id` is written back. If the app dies mid-loop the
booking stays `pending`; next pass the conflict check ignores its own event via
the stored `ek_event_id`, so a crash can't double-book or double-email.

**Mail.app send.** Write the `.ics` to a temp file, run AppleScript via
`osascript` (same shell-out pattern as `shortcuts run` in the busy light). Sender
pinned to the Exchange identity, `visible:false`:

```applescript
tell application "Mail"
    set newMsg to make new outgoing message with properties ¬
        {subject:"Confirmed: 30-min intro — Thu 2pm", content:"Hi Sam, ...", visible:false}
    tell newMsg
        make new to recipient with properties {address:"sam@example.com"}
        make new attachment with properties {file name:(POSIX file "/tmp/invite.ics")}
        set sender to "Adam Brown <adam.brown@altra.cloud>"
    end tell
    send newMsg
end tell
```

First send triggers a one-time macOS Automation permission prompt
("MeetingReminder wants to control Mail"). App is already non-sandboxed, so this
is allowed.

**Reused, not rebuilt:** Supabase HTTP client, Keychain key, EventKit access, the
shell-out pattern. Genuinely new: the poll loop, the conflict predicate, and the
AppleScript composer.

---

## Event-type management

**v1 — SQL seed.** Insert 2–3 event types directly via the Supabase dashboard or
a seed script; the page reads them immediately. Ships the valuable booker-facing
loop first and proves it works before investing in UI.

**Fast-follow — "Booking" Settings tab.** An 11th tab in `SettingsView` doing CRUD
against `event_types` over the existing Supabase client (service-role key): list
with active toggle, add/edit (title, slug, duration, buffers, min-notice,
max/day, weekly-hours grid), and a "Copy booking link" button. The weekly-hours
editor (7-row time-range grid) is the only non-trivial UI.

---

## Build order (suggested)

1. **Supabase schema** — tables, constraint, view, RLS policies. Seed one event type.
2. **Mac app `BookingPollService`** — poll, conflict check, EKEvent create,
   status flip. (Email stubbed.) Verify a manually-inserted `pending` row
   becomes a real calendar event.
3. **Mail.app send** — `.ics` builder + AppleScript composer. Verify confirmation
   email arrives from `adam.brown@altra.cloud`.
4. **Booking page** — `/book/<slug>` route in `availability-page/`: slot
   generation, booking form, insert, "requested" confirmation screen.
5. **Min-notice + push-interval tuning.** Exercise both races end-to-end.
6. **Fast-follow:** Booking Settings tab.

---

## Explicitly out of scope (v1)

- Reschedule / cancel links for the booker (add later; cancel = flip status +
  delete EKEvent + notify).
- Payment, round-robin, team scheduling, multiple hosts.
- Reminders to the booker (their own `.ics` handles calendar reminders).
- Real Exchange attendee tracking / accept-decline (impossible without Graph;
  the `.ics` is the substitute).
- Settings-tab management UI (deferred to fast-follow).

---

## Honest assessment vs Cal.com

| Cal.com capability | This design |
|--------------------|-------------|
| Show free/busy | ✅ (already shipped) |
| Multiple event-type links | ✅ |
| Self-service booking → calendar | ✅ (Mac-awake dependent) |
| Confirmation email + `.ics` from your real address | ✅ (Mail.app/Exchange) |
| Double-booking protection | ✅ (DB constraint + live conflict check) |
| Instant confirmation | ⚠️ "within a minute or two" |
| 24/7 booking when your Mac is off | ❌ (events confirm when the Mac wakes) |
| Reschedule/cancel self-service | ❌ v1 (fast-follow) |
| Attendee accept/decline tracking | ❌ (needs Graph) |

**Net:** ~85–90% of the everyday Cal.com experience, with zero new paid services
and no corporate-IT dependencies. The only structural limitation is the
Mac-awake requirement for confirmation — already accepted when choosing the
EventKit write-back path.
