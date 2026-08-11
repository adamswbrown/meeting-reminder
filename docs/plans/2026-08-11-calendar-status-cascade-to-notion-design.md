# Cascade calendar-event status changes into Notion (row + Pre-Call Briefing)

**Date:** 2026-08-11
**Status:** Design — approved, not yet implemented
**Owner:** Adam

---

## Problem

When a briefed meeting is **cancelled** or **rescheduled**, the Notion metadata does
not reliably reflect it, so downstream surfaces (the morning digest, the intraday
catcher, anyone reading Notion) still present the meeting as happening.

Concrete incident (2026-08-11): the `Advisory / Ask Adam between Adam Brown and
Taymour @ 13:00` call was cancelled, but a notification still presented it as
briefed/happening. Two root causes:

1. **The intraday skill mislabelled the cancel as a move** (title-only match over a
   14-day forward window grabbed an unrelated same-title booking at 08-12 09:00).
   Fixed separately in `automation/pre-call-briefing-intraday.md` — a MOVE now
   requires the same iCal UID. See memory `intraday-move-vs-cancel-uid`.
2. **The Mac app never records the cancellation back to Notion.** An organiser
   cancellation on Exchange almost always *deletes* the EventKit event (no
   `.canceled` tombstone), so it is a **disappearance**, not a readable status. The
   only detector for that today is the **orphan sweep**, which is:
   - opt-in via `calendarNotionSyncArchiveOrphans` (**off by default — and off for
     Adam**, verified 2026-08-11),
   - only sets `Sync State = Orphaned` on the *Calendar Events* row,
   - does **not** touch the linked *Pre-Call Briefing* at all,
   - skipped entirely on reactive runs.

So the Calendar Events row stays `Active` and the brief's `Meeting Outcome` is never
set. This design makes the **Mac app the authoritative writer** of "is this meeting
still happening," cascading to **both** the row and the linked brief.

## Decisions (from brainstorming)

| Question | Decision |
|----------|----------|
| Where does the logic live? | **Mac app** (`CalendarNotionSyncService`), not the skill. |
| Cancel signal | **Disappeared + in-window** — row was `Active`, event now absent from the fetch, its date inside the run window. |
| Timeliness | **Reactive (~2 min) + daily 06:00** backstop. |
| Gating | **Decoupled** from `calendarNotionSyncArchiveOrphans`. New dedicated toggle `calendarNotionSyncCascadeStatus`, **default ON**. Cascade only ever writes status metadata — never archives. |

## Scope — two flows

### A) Reschedule (a one-off that moved)
Already partly handled: a moved one-off re-upserts under the same Apple Event ID with
a new `Date`, so the Calendar Events row re-dates in place today.

**New behaviour:** when the upserter detects the row's `Date` actually changed
(incoming start ≠ `ExistingRow.eventDate`) **and** the row has a linked Pre-Call
Briefing, cascade the new start onto the brief's `Date & Time`. If the brief had
previously been marked `Meeting Outcome = Cancelled`, clear it / set `Rescheduled`
(a revived meeting). The Mac app owns only the **structured metadata** — it does not
rewrite the brief body (that stays the skill's job).

### B) Cancellation (a disappearance, in-window)
Extend the disappearance detector: a row that was `Active`, whose event is now absent
from the fetch, and whose `eventDate` is inside the run window, gets:
- *Calendar Events row* — `Status = Cancelled` **and** `Sync State = Orphaned` in a
  single PATCH (today's sweep only writes `Sync State`).
- *Pre-Call Briefing* (if linked) — `Meeting Outcome = Cancelled`. Never deletes.

## Field-level writes

**Reschedule:**
- Row: re-dated by normal upsert; `Sync State = Active`, `Status` recomputed by mapper.
- Brief: PATCH `Date & Time` → new start; `Meeting Outcome` cleared/`Rescheduled` if it was Cancelled.

**Cancellation:**
- Row: PATCH `Status = Cancelled`, `Sync State = Orphaned`.
- Brief: PATCH `Meeting Outcome = Cancelled`.

**Brief pageID lookup:** extract from `ExistingRow.properties[preCallBriefingRelation]`
(the relation array's first `id`) — a small helper next to the existing
`relationCount`. No extra Notion query. Empty relation → row-only update.

## Idempotence & churn

- Reuse the existing `PropertyDiff` guard on the row: if already
  `Status=Cancelled / Sync State=Orphaned`, no PATCH.
- Cascade the brief write **only on the transition** into Cancelled this run (not on
  every run where the row is already Orphaned) so a cancellation cascades exactly once
  and we avoid a per-brief read.

## Reactive path & false-positive safety

Reactive runs currently pass `archiveOrphans:false` and skip the sweep. Add a
**cascade-only** pass on reactive runs using the reactive window (now→+30d) as the
in-window guard. Guards:

1. **In-window only** — a row dated outside the run window is never touched (existing guard).
2. **Skip recurring rows on the reactive path** — a moved recurring *occurrence*
   vanishes from EventKit without being cancelled (the ICS-vs-EventKit gap; see memory
   `ics-vs-eventkit-recurrence-gap`). Rows whose Apple Event ID ends `_YYYY-MM-DD` or
   contains `/RID=` are excluded from the *reactive* cancel cascade; the daily full run
   reconciles them with its wider window.
3. **Never cascade a `touched` row** — if it upserted this run, it exists.
4. **Append-only on manual work** — a row with Meeting Notes populated stays `Stale`,
   not Cancelled (mirrors the existing B2 rule).

## Coexistence with the intraday skill

The skill's REMOVED path may also set `Meeting Outcome = Cancelled` / re-date the
brief. Both writes are idempotent and converge — no conflict. The Mac app just gets
there first and reliably; the skill becomes a backstop.

## New settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `calendarNotionSyncCascadeStatus` | Bool | **true** | Cascade cancel/reschedule status onto the Calendar Events row + linked Pre-Call Briefing. Independent of `calendarNotionSyncArchiveOrphans`. |

## Open item to verify before coding

`defaults read com.meetingreminder.app calendarNotionSyncEnabled` reads unset even
though the sync log is actively written — confirm where these toggles are actually
persisted (suite name / container) so the new toggle lands in the same store and the
Settings UI reads it correctly.

## Testing

- **Pure mapper/classifier tests** (no EventKit): given an `ExistingRow` (Active,
  in-window, absent from touched) → expect a Cancelled row PATCH + brief
  `Meeting Outcome = Cancelled`. Given a recurring Apple Event ID on the reactive
  path → expect **no** cascade. Given a date change vs `eventDate` → expect a brief
  `Date & Time` PATCH.
- **Idempotence:** second run over an already-Cancelled row → no PATCH.
- **Brief pageID extraction** helper unit test against a real Notion relation payload.
- **Manual acceptance:** cancel a test meeting mid-day → within ~2 min the Calendar
  Events row shows `Status=Cancelled` and the linked brief shows
  `Meeting Outcome=Cancelled`.

## Explicitly out of scope

- Rewriting brief bodies (skill's job).
- Deleting/archiving Notion pages (cascade only flips status metadata).
- Detecting "soft" no-shows where the invite was never actually cancelled.
