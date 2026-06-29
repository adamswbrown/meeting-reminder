# Cal.com → Notion Gap: Design

**Date:** 2026-06-29  
**Status:** Design — ready for implementation

---

## Problem

When a Cal.com booking arrives and `CalComSyncService` syncs it to EventKit, nothing creates a Notion Meeting Notes page or Pre-Call Brief for it. The `CalendarNotionSyncService` daily run will eventually create a *Calendar Events* row (via Exchange), but:

- There's no Meeting Notes page for the booking
- There's no Pre-Call Brief surfaced in the overlay
- The overlap detection in `RelationLinker` works by title match — it could link after the fact, but only if a Meeting Notes page already exists with the right title

Cal.com bookings are quiet arrivals. They need the same downstream Notion treatment as manually created meetings.

---

## Solution

When `CalComSyncService` creates **or tags** an EKEvent for a new booking, it checks whether a Meeting Notes page already exists for that booking. If not, it creates one via `NotionService.createMeetingPage()`. This mirrors exactly what the overlay's "Open Notion" button does — reusing the existing path.

**Only fires on new bookings** — not on already-tagged Exchange events (where a Notion page may already exist from a prior sync).

---

## Architecture

```
CalComSyncService.syncBooking(booking)
        │
        ├── findTaggedEvent → exists → .skipped (no Notion action)
        │
        ├── findExchangeEvent → found → tag it → .tagged
        │         └── isNewBooking=false → skip Notion (Exchange event
        │                                  already has its own Notion row
        │                                  via CalendarNotionSyncService)
        │
        └── create new EKEvent → .created → isNewBooking=true
                  └── createNotionPageIfNeeded(booking)
                          └── NotionService.createMeetingPage(
                                title:     booking.title,
                                startDate: booking.startDate,
                                attendees: booking.attendees,
                                location:  booking.location
                              )
```

**Why only `.created`, not `.tagged`?**
When we find an Exchange event and tag it, the Exchange calendar already created it, which means `CalendarNotionSyncService` will pick it up on its next run and create a Calendar Events row. `RelationLinker` can then auto-link a Meeting Notes page if one with a matching title exists. Creating an extra page here would duplicate that logic and race against it. Only truly new EKEvents (ones we created ourselves) lack that pipeline.

---

## New file

### `MeetingReminder/Services/CalComNotionBridge.swift`

A thin coordinator. Keeps `CalComSyncService` focused on EventKit and `NotionService` on Notion.

```swift
@MainActor
final class CalComNotionBridge {
    private let notion: NotionService

    init(notion: NotionService) {
        self.notion = notion
    }

    /// Creates a Notion Meeting Notes page for a newly-synced Cal.com booking.
    /// No-ops if the Notion token isn't configured.
    func createPageIfNeeded(for booking: CalComBooking) async {
        guard notion.isConfigured else { return }
        let title = booking.title ?? "Meeting"
        let attendeeNames = booking.attendees?.map { $0.name } ?? []
        let start = booking.startDate ?? Date()
        await notion.createMeetingPage(
            title: title,
            startDate: start,
            attendeeNames: attendeeNames,
            location: booking.location
        )
    }
}
```

---

## Modified files

### `MeetingReminder/Services/CalComSyncService.swift`

- Add `private let notionBridge: CalComNotionBridge?`
- `init(calCom:eventStore:notionBridge:)` — bridge is optional (nil = no Notion)
- In `syncBooking`, after creating a new EKEvent:
  ```swift
  case .created:
      if let bridge = notionBridge {
          Task { await bridge.createPageIfNeeded(for: booking) }
      }
  ```

### `MeetingReminder/MeetingReminderApp.swift`

```swift
let calComNotionBridge = CalComNotionBridge(notion: notion)
let calComSync = CalComSyncService(calCom: calCom, notionBridge: calComNotionBridge)
```

### `MeetingReminder/Services/NotionService.swift`

Check if `createMeetingPage` already accepts the right parameters. If it requires an `EKEvent`, add a parallel overload that takes title/date/attendees directly. No breaking changes — the existing EKEvent-based call is unchanged.

---

## Open question: duplicate Notion pages

If the Exchange calendar event eventually syncs to Notion via `CalendarNotionSyncService`, and `RelationLinker` auto-links it to the Meeting Notes page created here, that's the ideal outcome — no duplicates, just a linked pair.

The risk is: `CalendarNotionSyncService` creates a Calendar Events row AND a Meeting Notes page gets created here, and then `RelationLinker` finds both and links them. This is actually correct behaviour. The only edge case is if someone manually creates a Meeting Notes page with the same title before the next Notion sync — `RelationLinker` would find two candidates and skip (>1 hit = ambiguous). Acceptable.

---

## Rollback

Remove the `notionBridge` parameter from `CalComSyncService.init` (or pass `nil`). No DB changes.

---

## What this does NOT do

- No Pre-Call Brief creation — those are triggered by a Notion automation on the Calendar Events DB, not by the app. Once the Calendar Events row exists (via `CalendarNotionSyncService`), the automation fires. This is by design.
- No deletion of Notion pages when a booking is cancelled — `CalComSyncService` deletes the EKEvent on cancellation; the Meeting Notes page is user data and stays (same policy as `CalendarNotionSyncService` B2 orphan handling).
