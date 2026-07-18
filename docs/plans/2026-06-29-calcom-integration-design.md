# Cal.com Integration Design

**Date:** 2026-06-29  
**Status:** Approved — ready for implementation

---

## Problem

The existing booking system (`BookingPollService` → Supabase `pending` → Mac confirms) requires the Mac to be awake to confirm bookings, create EKEvents, and send emails. The Mac is the single point of failure in the critical path.

Adam has an existing Cal.com account (`adamswbrown`) with 3 live event types but cannot access the Cal.com web UI due to corporate conditional access. The API is the only management door.

---

## Solution

Cal.com becomes the **source of truth for new bookings**. The Mac app gains a Cal.com management console (Settings tab) since the web UI is inaccessible. A new `CalComSyncService` replaces `BookingPollService` as the booking sync loop — bookings now complete entirely without the Mac, which syncs EKEvents, Notion etc. when it next wakes.

---

## Architecture

```
  Booker visits cal.com/adamswbrown/<slug>
           │
           ▼
    Cal.com (hosted)
    ├── reads Adam's Exchange calendar for availability (already connected via Office365)
    ├── creates calendar event on Exchange
    └── sends confirmation email + Teams link
           │
           │ Cal.com API (poll every 5 min + on wake)
           ▼
    Mac app CalComSyncService
    ├── creates EKEvent locally (for overlays, busy light, context panel)
    ├── tags event [calcom-booking-id:<uid>] for idempotency
    └── triggers existing Notion sync pipeline

    Mac app Settings → Cal.com tab
    ├── manage event types (create, edit, delete, toggle hidden)
    ├── manage schedules (working hours per day)
    └── view/cancel/reschedule upcoming bookings
```

---

## Cal.com Account

**Username:** adamswbrown  
**Existing event types:**

| ID | Title | Duration | Slug |
|----|-------|----------|------|
| 4311080 | Dr Migrate – Deep-Dive / Planning | 60 min | `dr-migrate-deep-dive` |
| 4311081 | Dr Migrate – First Steps / Kickoff | 45/60 min | `dr-migrate-first-steps` |
| 3589141 | Catch-up | 15–90 min | `catchup` |

All use `office365-video` (Teams) and have a custom `customer_company_name` field.

---

## API

**Base URL:** `https://api.cal.com/v2/`  
**Auth:** `Authorization: Bearer <calComAPIKey>` + `cal-api-version: 2024-06-14`  
**Key storage:** Keychain key `calComAPIKey`

### Endpoints used

```
# Event types
GET    /v2/event-types
POST   /v2/event-types
PATCH  /v2/event-types/{id}
DELETE /v2/event-types/{id}

# Schedules
GET    /v2/schedules
GET    /v2/schedules/{id}
PATCH  /v2/schedules/{id}

# Bookings
GET    /v2/bookings?status[]=upcoming&afterStart=<ISO>&take=50
GET    /v2/bookings/{uid}
DELETE /v2/bookings/{uid}    (cancel)
PATCH  /v2/bookings/{uid}    (reschedule)
```

---

## New Files

### `MeetingReminder/Models/CalComModels.swift`

Codable structs:
- `CalComEventType` — id, ownerId, title, slug, description, lengthInMinutes, lengthInMinutesOptions, minimumBookingNotice, beforeEventBuffer, afterEventBuffer, hidden, bookingUrl, locations, bookingFields
- `CalComSchedule` — id, name, timeZone, isDefault, availability (days + time ranges), overrides
- `CalComBooking` — uid, title, start, end, status, attendees, location, metadata, eventTypeId
- `CalComAttendee` — name, email, timeZone
- Input types for create/update: `CalComEventTypeInput`, `CalComScheduleInput`

### `MeetingReminder/Services/CalComService.swift`

Thin REST wrapper. Single `URLSession`. API key injected from Keychain per-call.

```swift
// Key methods
func fetchEventTypes() async throws -> [CalComEventType]
func createEventType(_ input: CalComEventTypeInput) async throws -> CalComEventType
func updateEventType(id: Int, _ input: CalComEventTypeInput) async throws -> CalComEventType
func deleteEventType(id: Int) async throws

func fetchSchedules() async throws -> [CalComSchedule]
func fetchSchedule(id: Int) async throws -> CalComSchedule
func updateSchedule(id: Int, _ input: CalComScheduleInput) async throws -> CalComSchedule

func fetchUpcomingBookings(after: Date) async throws -> [CalComBooking]
func cancelBooking(uid: String, reason: String?) async throws
func rescheduleBooking(uid: String, newStart: Date) async throws

func testConnection() async throws -> Bool
```

Error type: `CalComError` (unauthorized, notFound, rateLimited, serverError, decodingError).

### `MeetingReminder/Services/CalComSyncService.swift`

Replaces `BookingPollService` as the booking sync loop. Owned by `MeetingReminderApp`.

**Behaviour:**
- Polls Cal.com every 5 min while awake (timer)
- Triggers once on `NSWorkspace.didWakeNotification`
- Fetches bookings with `status=upcoming&afterStart=now-1h` (1h lookback catches bookings made while asleep)
- For each booking not tagged in EventKit:
  - Creates `EKEvent` on default Exchange calendar
  - Notes include `[calcom-booking-id:<uid>]` for idempotency
  - Sets attendees, location (Teams link), title from Cal.com
- For bookings with status `cancelled`: finds and deletes the local EKEvent if present
- Publishes: `@Published var lastSyncedAt: Date?`, `@Published var lastSyncResult: String`
- UserDefaults: `calComSyncEnabled` (Bool, default false), gated by `calComAPIKey` presence

**Idempotency:** before creating, searches EventKit for notes containing `[calcom-booking-id:<uid>]`. Safe to re-run.

### `MeetingReminder/Views/CalComSettingsView.swift`

New tab in `SettingsView`. Four sections:

**Connection**
- API key field (SecureField) → stored in Keychain
- "Test connection" button → calls `testConnection()`, shows green ✓ or error
- Connected account display (username, owner name)
- Disconnect button

**Event Types**
- List of event types (title, duration, slug, hidden toggle)
- Tap to expand: edit title, description, duration(s), buffers, min notice
- "New event type" button → sheet with required fields
- Delete (with confirmation)
- "Open booking link" → opens `cal.com/adamswbrown/<slug>` in browser

**Schedules**
- List schedules with default indicator
- Tap to expand: edit days/hours, timezone
- No create (keep existing schedule, just edit)

**Bookings**
- Upcoming bookings list (title, attendee name, start time, status)
- Cancel action (with reason field)
- Reschedule action (date/time picker)
- "Sync now" button + last sync timestamp + result

---

## Modified Files

### `MeetingReminder/Services/BookingPollService.swift`

Add guard at the top of `startPolling()`:

```swift
guard KeychainHelper.load(key: "calComAPIKey") == nil else {
    // Cal.com sync is active — legacy Supabase poll disabled
    return
}
```

Keeps the Supabase flow working for anyone without a Cal.com key configured.

### `MeetingReminder/MeetingReminderApp.swift`

- Instantiate `CalComSyncService(calComService: calComService)`
- Pass to `SettingsView` via environment or direct init
- Call `calComSyncService.startIfEnabled()` on launch

### `MeetingReminder/Views/SettingsView.swift`

Add `.tabItem { Label("Cal.com", systemImage: "calendar.badge.clock") }` tab containing `CalComSettingsView`.

### `MeetingReminder.xcodeproj/project.pbxproj`

Add 4 entries per new file (PBXBuildFile, PBXFileReference, group children, Sources build phase). Use globally-unique object IDs — mirror pattern from existing files.

---

## UserDefaults Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `calComSyncEnabled` | Bool | false | Enable the Cal.com booking sync loop |
| `calComLastSyncedAt` | Date | nil | Timestamp of last successful sync |
| `calComLastSyncResult` | String | nil | e.g. `synced=2 cancelled=0 skipped=1` |

## Keychain Keys

| Key | Purpose |
|-----|---------|
| `calComAPIKey` | Cal.com API key (`cal_live_...`). Presence of this key activates Cal.com mode and disables the legacy Supabase poll loop. |

---

## Next.js

No changes required. Existing `/book/<slug>` Supabase flow remains for `intro-30` / `deep-60`. Cal.com event types are shared as direct `cal.com/adamswbrown/<slug>` links from the availability page.

---

## What Does NOT Change

- `AvailabilityPushService` — continues pushing free/busy to Supabase for the public availability page
- `NotionService` / `CalendarNotionSyncService` — unchanged; `CalComSyncService` calls into the existing EKEvent creation path which already triggers Notion
- `GraphMailService` / booking emails — Cal.com sends confirmation emails natively; the Mac app no longer sends booking confirmation emails
- Busy light, overlays, context panel — all driven by EventKit as before; `CalComSyncService` just ensures the EKEvents exist locally

---

## Rollback

Remove `calComAPIKey` from Keychain → `BookingPollService` resumes its Supabase poll loop automatically. No code changes needed to revert.
