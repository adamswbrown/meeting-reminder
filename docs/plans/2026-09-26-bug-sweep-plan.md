# Bug sweep — 2026-09-26

Source: 4-agent read-only audit (Cal→Notion sync, MeetingMonitor, intraday briefs, Cal.com/booking). 32 findings; top ones re-verified against the code.

## Execution

- 5 workstreams, split by **file ownership** so they can run in parallel without merge conflicts.
- Each runs in its own git worktree on branch `bugsweep/<ws>` cut from `main`.
- Each: TDD where logic is pure (failing test → fix → pass), build + full test run, one commit per fix.
- Each gets an independent adversarial review; review findings are fixed before hand-back.
- **No pushes, no PRs** — branches are left local for Adam to review, then push to `mine`.
- New test files need pbxproj entries; each workstream owns a unique object-ID prefix to avoid collisions.

| WS | Branch | Owns files | pbxproj ID prefix |
|----|--------|-----------|-------------------|
| A | `bugsweep/calsync` | CalendarNotionSyncService, CalendarChangeWatcher, CalendarSyncCascade, CalendarSyncTypes | `BA0000xx` |
| B | `bugsweep/monitor` | MeetingMonitor, VideoLinkDetector, CalendarService, ScreenDimmer | `BB0000xx` |
| C | `bugsweep/intraday` | PreCallBriefTriggerService, PreCallBriefService, FoundationModelsBriefService | `BC0000xx` |
| D | `bugsweep/notion-notes` | NotionService, MeetingReminderApp (join path), CalComNotionBridge | `BD0000xx` |
| E | `bugsweep/booking` | BookingPollService, CalComSettingsView, CalComSyncService, CalComService, GraphMailService, AvailabilityPushService, KeychainHelper | `BE0000xx` |

## A — Cal→Notion sync

1. **Orphan sweep cancels a whole calendar** (`:733`, `:1335`). Only sweep rows whose Source Calendar was fetched this run; skip sweep for a calendar that returned 0 events; force `cascadeStatus=false` on reactive runs.
2. Meeting moved >30d out → Cancelled; revival never resets brief `Meeting Outcome`. Reset outcome on revival.
3. Skip-rule on recurring meeting cancels series-master row. Mark bare UID present when any occurrence is skip-filtered.
4. `POST /pages` retried after timeout/5xx → duplicates. Don't retry non-idempotent POST; on failure re-run `findPageID` before retrying.
5. Calendar edits during a run/cooldown dropped. Set a "dirty" flag and schedule a follow-up after cooldown.
6. `event(withIdentifier:)` given `/RID=` external ID (plausible). Verify; switch to a correct lookup or remove dead check and document.
7. 429 handling ignores `Retry-After`, aborts run. Honour `Retry-After`, more attempts for 429.

## B — Meeting monitor

1. Stale `endDate` for in-progress meeting (`:618`). Re-resolve current event from `calendarService.events` before end check.
2. Back-to-back: previous call's app quit / audio ends the new meeting. Only accept app-quit/audio end after the joined meeting's own call is observed active.
3. Teams `/meet/`, `teams.live.com`, SafeLinks not detected (`VideoLinkDetector.swift:12`).
4. Screen dimming re-dims after Dismiss; brightness ratchets. Skip dismissed events; capture original brightness once.
5. Snooze replays banner + beep. Don't clear already-fired lower tiers on snooze.
6. Expired-snooze re-fire branch is dead (`:445`). Order cleanup after the re-fire check.
7. Break overlay picks overlapping/finished meeting. Next event must start ≥ now.
8. (design) All-day-ish in-progress block hides countdown — respect `meetingEndedIDs`.

## C — Intraday briefs

1. **Watchdog never finishes if parent exited but pipe held** (`:796`). Always `finish` after timeout.
2. Calendar-filter change → burst of false removed/new. Suppress diff for one cycle after filter change; cap burst size.
3. Cancelled-while-queued meeting still briefed. Removal cancels matching pending brief.
4. Title-only match drops a new meeting's brief. Require same start-day/UID proximity, not title alone.
5. Auto-matched brief cached forever. Only persist user-attached matches; re-match automatic ones.
6. FoundationModels retry reuses full session. New session for minimal retry.
7. Legacy FileHandle write can crash. Use throwing APIs.

## D — Notion meeting notes

1. **Join creates duplicate note; relation overwrite unlinks real note** (`NotionService.swift:462`, `MeetingReminderApp.swift:374`). `findMeetingNote` before create; append to relation instead of replace.
2. Cal.com bridge key (`calcom-<uid>`) differs from join key → two pages. Share a dedupe path.

## E — Booking / Cal.com / availability

1. **Booking poll keeps running after Cal.com key saved** (`BookingPollService.swift:100`). Gate in `pollOnce`; `saveKey()` stops poll, starts CalComSync.
2. Saving key doesn't start `CalComSyncService`.
3. Duplicate EKEvent when Exchange copy late/renamed. Later reconciliation: when a tagged-untagged pair appears, delete the app-created one.
4. `invalid_grant` wipes token on recoverable AADSTS codes. Only delete on AADSTS70000/70008/50173-style expiry codes.
5. Cal.com bookings not paginated. Loop with `skip`.
6. Availability delete URL too long → 414. Batch the `not.in` or delete by window + upsert timestamp.
7. Free events shown as busy. Drop `.free` events from the push (match legacy conflict check).
8. Tagged (Exchange-matched) Cal.com meetings never get a notes page. Fire bridge on `.tagged` too (safe after D).

## Merge order

D before E (E item 8 relies on D's dedupe). Others independent. `project.pbxproj` may conflict on adjacent lines — resolve by keeping both entries.
