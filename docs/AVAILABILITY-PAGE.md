# Availability Page

A public read-only **"when am I free?"** web page, backed by free/busy data the
Mac app pushes to **Supabase** every few minutes. No titles, no attendees are
ever exposed — the public web frontend reads a **sanitised SQL view**.

```
Mac app (AvailabilityPushService)  --service-role write-->  Supabase
                                                              │
                                          public_freebusy view (sanitised)
                                                              │
Vercel / Next.js page  <--anon-key read--------------------- ┘
```

## Two halves, two repos

| Half | Where | What it is |
|------|-------|-----------|
| **Push** | this repo — `Services/AvailabilityPushService.swift` | Snapshots EventKit, writes to Supabase on a timer |
| **Frontend** | separate repo — `adamswbrown/availability-page` (private) | Next.js page deployed to Vercel that reads the sanitised view |

> The Next.js source used to live in `availability-page/` here but was moved out
> (`b795966 chore: move availability-page to its own repo`). Only a stale
> `.next/` build dir may remain on disk — it's gitignored. **All frontend work
> happens in the separate repo.**

---

## 1. Supabase setup

Create a Supabase project, then create the schema the push service expects.
The app writes these columns (see `PushEvent.toJSONDictionary()`):

```sql
-- Raw events the Mac app writes (service-role only).
create table public.calendar_events (
  event_id       text primary key,         -- "<ekIdentifier>_<startISO>"
  title          text,                     -- never exposed publicly
  start_utc      timestamptz not null,
  end_utc        timestamptz not null,
  is_all_day     boolean default false,
  is_tentative   boolean default false,
  status         text,                      -- confirmed | tentative | cancelled
  calendar_name  text,
  has_video_link boolean default false,
  source         text default 'macos-eventkit'
);

-- Single-row sync heartbeat for the "data is N min old" pill.
create table public.sync_state (
  id                   int primary key default 1,
  last_synced_at       timestamptz,
  next_sync_window_end timestamptz,
  events_in_window     int
);
insert into public.sync_state (id) values (1) on conflict do nothing;

-- Sanitised public view: busy blocks only, NO title/attendees.
create view public.public_freebusy as
  select event_id, start_utc, end_utc, is_all_day, is_tentative, status, has_video_link
  from public.calendar_events
  where status <> 'cancelled';
```

**Lock it down** so the anon (publishable) key can read *only* the sanitised
view, never the raw table:

```sql
alter table public.calendar_events enable row level security;  -- no anon policy = no anon access
grant select on public.public_freebusy to anon;
grant select on public.sync_state     to anon;
```

The Mac app writes with the **service-role key**, which bypasses RLS — that key
stays in macOS Keychain and never reaches the browser.

> Reference project ref used historically: `djlijptucgpcxennmkch`. Use your own.

## 2. Configure the Mac app (push side)

1. **Settings → Availability tab.**
2. **Supabase project** section:
   - **Project URL** — `https://<ref>.supabase.co`
   - **Service-role key** — Supabase → Settings → API → `service_role` (the
     secret `eyJ…` one). Stored in **Keychain**, never in UserDefaults.
3. **Save & Sync** — fires an immediate push so you get instant feedback.
4. Toggle **Enable availability push** on.

### Settings keys

| Key | Store | Default | Meaning |
|-----|-------|---------|---------|
| `availabilityPushEnabled` | UserDefaults | false | Master on/off + timer |
| `supabaseProjectURL` | UserDefaults | "" | `https://<ref>.supabase.co` |
| `supabaseServiceRoleKey` | **Keychain** | — | Write key (bypasses RLS) |
| `availabilityPushIntervalMinutes` | UserDefaults | 5 | Push cadence |
| `availabilityPushWindowDays` | UserDefaults | 14 | Days forward to snapshot |

**Behaviour notes:**
- Honours the `enabledCalendarIDs` calendar filter; drops events you've
  **declined**; keeps tentative (flagged `is_tentative`).
- Includes **all-day** events (so OOO blocks count as busy) — unlike the
  meeting-overlay path, which filters them out.
- Each push **deletes** any rows in the window that are no longer in the
  EventKit snapshot, so cancellations/reschedules disappear from the page.
- Push only runs **while the Mac is awake**; the `sync_state` heartbeat lets the
  frontend show a staleness pill.

## 3. Deploy the frontend

In the separate `adamswbrown/availability-page` repo:

```bash
cp .env.local.example .env.local   # paste Supabase URL + publishable (anon) key
pnpm install
pnpm dev                            # http://localhost:3000
```

Deploy: import the repo in **Vercel**, set two env vars in Project Settings →
Environment Variables (both are `NEXT_PUBLIC_*`, safe for the browser):

```
NEXT_PUBLIC_SUPABASE_URL=https://<ref>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=sb_publishable_…
```

Working hours, slot length, and look-ahead are configured in the frontend's
`lib/config.ts` (Mon–Fri 09:00–17:00 Europe/London, lunch blocked, 45-min min
slots, 14-day look-ahead by default). The page revalidates every 5 min via
Next.js ISR.

## Troubleshooting

- **"Not configured"** — Project URL or service-role key missing. Re-enter in
  the Availability tab; the key lives in Keychain so a fresh machine needs it
  re-pasted.
- **HTTP 401/403 on push** — wrong key. The push needs the **service_role**
  secret, not the anon/publishable key.
- **Page shows events but no titles** — correct and intended; the public view
  strips them.
- **Stale pill stuck** — the Mac is asleep or push is disabled; `sync_state`
  isn't updating. Re-enable, or Save & Sync to force one.
