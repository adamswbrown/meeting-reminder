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
3. **Change detection:** **Reuse the existing `PropertyDiff` no-op
   short-circuit.** The upserter (`CalendarSyncUpserter.run`) already compares
   incoming properties against the row's current Notion state and skips the
   PATCH when nothing changed (counted as `unchanged`). So Notion — and
   therefore Co-Work — already only ever sees a write for a genuinely changed
   event. **No new hash column or local cache is needed.**
4. **Reactive scope:** narrow window `now → +30d`. The reactive run does one
   read-only paginated query of the Notion DB to build the diff map, then
   `PropertyDiff` ensures only changed events get written. The 2-min floor
   bounds this to ~30 reads/hour — trivial for Notion's rate limit.

## Revision note (2026-06-12)

The original design proposed a `Sync Hash` column + on-disk hash cache +
dupe-guard query to deliver "changed-events-only." During plan grounding we
found the existing upserter **already** guarantees changed-events-only *writes*
via `PropertyDiff`. The hash cache only saved the per-trigger Notion read, which
the 2-min floor already makes negligible. **Dropped** (YAGNI): no
`CalendarSyncCache`, no `Sync Hash` column, no migration 004, no dupe-guard
query. The feature collapses to: a change watcher + a narrow-window reactive
variant of the existing run.

EventKit has **no delta API**. `.EKEventStoreChanged` only says *something*
changed — not what. We therefore re-query the narrow window on each trigger and
let `PropertyDiff` decide what (if anything) to write.

## New components

1. **`ReactiveSyncScheduler`** (pure decision logic, in
   `Services/CalendarChangeWatcher.swift`)
   - `fireTime(changeAt:lastRunAt:) -> Date` implementing 30s debounce + 2-min
     floor. No NotificationCenter/Timer — unit-testable in isolation.

2. **`CalendarChangeWatcher`** (`Services/CalendarChangeWatcher.swift`)
   - Owns an `EKEventStore`, subscribes to `.EKEventStoreChanged`.
   - On each notification, computes `fireTime` via `ReactiveSyncScheduler` and
     (re)schedules a single coalesced `Timer` — never more than one pending run.
   - On fire, calls back into `CalendarNotionSyncService.runReactive()` on the
     main actor; records `lastRunAt`.
   - Installed/torn down by the service when
     `calendarNotionSyncReactiveEnabled` flips.

3. **`CalendarSyncReader.fetchEvents(in:from:to:)`** — parameterized-window
   overload; the existing 90/30 `fetchEvents(in:)` delegates to it.

4. **`CalendarNotionSyncService.runReactive()`** — narrow-window
   (`now → +30d`) variant of the run. Shares the upsert pipeline with
   `runNow()` via a private `run(mode:dryRun:)`; forces `archiveOrphans:false`
   and skips the rolling-week patch.

5. **New setting** `calendarNotionSyncReactiveEnabled` (Bool, default false),
   plus service property + `CalendarChangeWatcher` install/teardown + Settings
   toggle.

## Reactive data flow

Trigger → 30s debounce → 2-min floor → `runReactive()`:

1. Resolve calendars (`enabledCalendars()` ?? Exchange fallback — same as
   `runNow`).
2. Fetch EventKit events `now → +30d`; apply skip rules + free/OOO filter
   (identical to `runNow`).
3. `expandToRows` → `(event, isSeriesMaster, sourceCalendarName)` rows.
4. `fetchExistingEvents` (read-only paginated query of Calendar Events DS).
5. `CalendarSyncUpserter.run(... archiveOrphans: false)` — `PropertyDiff` skips
   unchanged rows; only genuinely-changed events are PATCHed/created.
6. B1 auto-link runs as in `runNow` (only on rows with empty relations).
7. **Skip** the rolling-week view patch (daily-only).

Net Notion writes per reactive run = number of genuinely changed events
(`PropertyDiff` guarantees it). Zero changes → zero writes → zero Co-Work
webhooks.

## Why orphan sweep must be off in reactive mode

The narrow `now→+30d` window means most rows in the full Notion DB are "not
touched" this run. If `archiveOrphans` ran, it would archive nearly the whole
ledger. Reactive therefore **always** passes `archiveOrphans: false`
regardless of the user's setting. Orphan archival stays exclusively on the
06:00 full-window run.

## Edge cases

- **App asleep during an edit** → watcher misses it; the 06:00 reconciler
  catches it. Acceptable by design.
- **`.EKEventStoreChanged` is coarse** → fires for *any* calendar change, even
  on calendars we don't sync. Harmless: a reactive run on an irrelevant change
  finds nothing to write (PropertyDiff → all `unchanged`), costing one
  read-only query. The floor bounds the frequency.
- **Recurring series** → each occurrence + series master has its own appleID,
  upserts independently. No special handling.
- **Floor + burst** → rapid edits collapse to one debounced run; an edit inside
  the floor reschedules the single pending timer to the floor boundary.
- **Overlap with daily run** → `runReactive` shares the `isRunning` guard, so it
  no-ops if the daily run is mid-flight (and vice versa).
- **Token missing** → reactive run no-ops with a log line (same guard as
  `runNow`).

## Error handling

- Reactive run wraps the same do/catch as `runNow`; failures log and update
  `lastResult`. Per-event create/PATCH failures are counted + logged by the
  existing upserter.

## Out of scope

- Direct app→Co-Work webhook (Notion owns it).
- Bidirectional sync.
- Any local hash cache, `Sync Hash` column, or dupe-guard query (dropped — see
  revision note).
- Any change to the existing 90/30 daily window or orphan/duplicate semantics.

## New setting

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `calendarNotionSyncReactiveEnabled` | Bool | false | Watch the calendar stream and sync changed events reactively |
