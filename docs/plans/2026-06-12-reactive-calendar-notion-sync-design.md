# Reactive Calendar → Notion sync (changed-events-only)

**Date:** 2026-06-12
**Status:** Design approved, not yet implemented

## Goal

Move from a once-daily batch sync to a **reactive** sync that watches the
Apple Calendar stream and pushes **only the changed events** into the Notion
*Calendar Events* DB. Notion's own automations then fire a webhook to **Co-Work**
to generate pre-call briefs. The daily 06:00 run stays as a full reconciler /
backstop.

## Decisions

1. **Latency model:** Hybrid — reactive trigger with a **2-minute floor**
   (no more than one reactive run every 2 min) plus a 30s debounce to settle
   bursts.
2. **Webhook origin:** **Notion fires it.** The app's only job is to keep
   Notion fresh; the Co-Work integration is a Notion automation on the
   Calendar Events DB. The app never calls Co-Work directly.
3. **Change detection:** **Content-hash guard.** Only PATCH a Notion row when a
   mapped field actually changed — so Notion (and therefore Co-Work) only ever
   sees a write for a genuinely changed event. This gates **both** the reactive
   path and the daily run.
4. **Reactive scope:** **Changed events only**, via a local hash cache. No
   full-window read of the Notion DB on reactive triggers.
5. **Dupe-guard:** new-event path does a targeted Notion query by `Apple Event
   ID` before creating, so a lost/stale cache can't create duplicate rows.

## Why changed-events-only needs a local cache

EventKit has **no delta API**. `.EKEventStoreChanged` only says *something*
changed — not what. To get true changed-events-only behaviour the app keeps its
own on-disk cache and diffs against it.

## New components

1. **`CalendarChangeWatcher`** (`Services/CalendarChangeWatcher.swift`)
   - Subscribes to `.EKEventStoreChanged` on the shared `EKEventStore`.
   - Owns the 30s debounce + 2-min floor. Coalesces — never more than one
     pending run queued.
   - Installed at launch when `calendarNotionSyncReactiveEnabled` is on;
     toggled live from Settings.

2. **Local hash cache** (`Services/CalendarSyncCache.swift`)
   - `Codable` map `appleEventID → { contentHash, notionPageID }`.
   - Persisted to
     `~/Library/Application Support/MeetingReminder/calsync-cache.json`.
   - Loaded at launch, rewritten after every run (reactive *and* daily).

3. **`CalendarEventMapper.contentHash(for:sourceCalendarName:)`**
   - Pure function, no EventKit import (testable with stub structs).
   - Hashes mapped fields in a fixed order: title, start (ISO8601
     Europe/London), end, location, sorted attendee emails, availability name,
     sourceCalendarName, isSeriesMaster.
   - SHA-256 (CryptoKit — already in SDK), hex, first 16 chars.

4. **`CalendarNotionSyncService.runReactive()`** — the changed-events-only flow.
   `runNow()` is unchanged in behaviour (full 90/30 reconciler) except it now
   also writes `Sync Hash` and rebuilds the cache.

5. **Migration `004-add-sync-hash-column`** — `ensureRichTextColumn("Sync Hash")`
   on the Calendar Events DS (idempotent, same pattern as 001–003).

6. **`CalendarSyncNotionQueries.findByAppleID(_:)`** — targeted DS query for the
   dupe-guard.

7. **New setting** `calendarNotionSyncReactiveEnabled` (Bool, default false).

## Reactive data flow

Trigger → 30s debounce → 2-min floor → `runReactive()`:

1. Resolve calendars (`enabledCalendars()` ?? Exchange fallback — same as
   `runNow`).
2. Fetch EventKit events `now → +30d`; apply skip rules + free/OOO filter
   (identical to `runNow`).
3. `expandToRows` → `(event, isSeriesMaster, sourceCalendarName)` rows.
4. Load cache. Per row compute `contentHash`, classify:
   - **not in cache** → *new*: targeted Notion query by `appleID` first
     (dupe-guard). Hit → adopt pageID + PATCH if hash differs. Miss → create.
   - **in cache, hash differs** → *changed*: PATCH using cached pageID.
   - **in cache, hash equal** → *skip* (no Notion call).
5. **Vanished:** cache entries whose start is in `now→+30d` but absent from the
   current fetch → archive/orphan **only if `archiveOrphansEnabled`**, else drop
   from cache.
6. B1 auto-link applied **only** to rows actually created/changed.
7. Update + persist cache (hash + pageID for every current event).
8. **Skip** rolling-week view patch and global orphan sweep — daily-only.

Net Notion writes per reactive run = number of genuinely changed events.
Zero changes → zero writes → zero Co-Work webhooks.

## Hash gating the daily run too

Today `runNow`'s upserter writes `Sync State=Active` + `archived:false` on
*every* update unconditionally — which under a Notion automation would fire a
Co-Work webhook for all ~180 rows every morning. The hash guard must gate the
daily upsert as well: only write when the incoming hash differs from the row's
stored `Sync Hash`. The daily run also reads `Sync Hash` back to rebuild the
local cache (e.g. after a reinstall).

## Edge cases

- **App asleep during an edit** → watcher misses it; the 06:00 reconciler
  catches it. Acceptable by design.
- **Cache lost (reinstall/corruption)** → first reactive run treats everything
  as new, but the dupe-guard adopts existing pageIDs (no duplicate rows). A
  one-time PATCH burst, then steady state. Next daily run fully rebuilds the
  cache from `Sync Hash`.
- **Recurring series** → each occurrence + series master has its own appleID,
  hashes/diffs independently. No special handling.
- **Floor + burst** → rapid edits collapse to one debounced run; an edit inside
  the floor schedules exactly one more run at the floor boundary.
- **Migration not yet applied** → reactive path calls `applyPending` once at
  first run (idempotent), guaranteeing `Sync Hash` exists.
- **Token missing** → reactive run no-ops with a log line (same guard as
  `runNow`).

## Error handling

- Reactive run wraps the same do/catch. On failure the cache is left
  **unchanged**, so failed events retry next trigger rather than being marked
  synced.
- Per-event create/PATCH failures are counted + logged; cache is updated only
  for events that succeeded.

## Out of scope

- Direct app→Co-Work webhook (Notion owns it).
- Bidirectional sync.
- Any change to the existing 90/30 daily window or orphan/duplicate semantics.

## New setting

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `calendarNotionSyncReactiveEnabled` | Bool | false | Watch the calendar stream and sync changed events reactively |
