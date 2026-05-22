# availability-page

Public read-only "when is Adam free?" page. Reads free/busy data that the
`MeetingReminder` Mac app pushes to Supabase every 5 minutes.

- **Data source**: `public.public_freebusy` view + `public.sync_state` row in
  the `djlijptucgpcxennmkch` Supabase project. No titles or attendees are
  ever exposed — the view is sanitised at the SQL level (column-level
  grants + RLS).
- **Working hours**: Mon–Fri 09:00–17:00 Europe/London, lunch 12:30–13:30
  blocked out. Minimum slot 45 min. Look-ahead 14 days. All configurable in
  `lib/config.ts`.
- **Refresh**: page revalidates every 5 min via Next.js ISR. Even when the
  Mac is offline, visitors see a "data may be out of date" pill so they
  aren't misled.

## Local dev

```bash
cp .env.local.example .env.local
# Edit .env.local — paste the Supabase URL + publishable (anon) key
pnpm install
pnpm dev
```

Open http://localhost:3000.

## Deploy

Push this folder to its own private GitHub repo (see "Migrating out of the
parent repo" below), then import it in Vercel. Add the two env vars in
Vercel's Project Settings → Environment Variables.

No build secrets required — both env vars are `NEXT_PUBLIC_*` and intended
for the browser anyway.

## Migrating out of the parent repo

This was scaffolded inside `adamswbrown/meeting-reminder` so the cloud
session that built it could persist the files. To move it to its own repo:

```bash
# From a fresh clone of meeting-reminder
cd availability-page
git init
git add -A
git commit -m "Initial scaffold"
gh repo create adamswbrown/availability-page --private --source=. --push
```

Then delete `availability-page/` from the meeting-reminder repo on the next
PR if you want the separation to be clean.

## Wider feature ideas (not built)

- Cal.com embed for real bookings (Cal.com is open source, free tier
  available, has both an inline embed and a popup; would slot in as an
  optional "or book directly" button next to each slot).
- iCal download per slot — visitors get a `.ics` they can drop into their
  calendar.
- Click → mailto with the slot pre-filled in the subject + body.
- Stack-ranked "best for me" slots — rank by overlap with the visitor's own
  working hours (assuming we can guess from their timezone).
- Public PNG snapshot at `/og.png` rendered with `@vercel/og` so the page
  previews well in email/Slack unfurls.
