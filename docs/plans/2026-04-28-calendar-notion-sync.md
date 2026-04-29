# Calendar → Notion Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a one-way sync feature *to the Meeting Reminder app* that pushes Apple Calendar events (Exchange-backed) into a pre-built Notion database called "Calendar Events". Runs daily at 06:00, triggerable from the menu bar dropdown and Settings, and exposes a single shell command for an Apple Shortcut. Becomes the canonical event ledger that downstream automations (e.g. 07:00 pre-call briefings) read from.

**Architecture:** A new `CalendarNotionSyncService` actor inside the existing app, wired up alongside the other services. Reuses `CalendarService`'s already-granted EventKit access. Reuses `KeychainHelper` for the Notion integration token (stored under a *separate* key from the existing `notionAPIToken` so this can have its own integration with access to the Operations subtree without disrupting the existing meeting-page flow). Pure-data transformation logic split out into testable types that don't import EventKit. New Settings tab for status + manual trigger. New menu bar dropdown row "Sync calendar to Notion now". Daily 06:00 trigger via a `Timer` scheduled when the app launches (the app is always running as a menu bar agent, so no launchd needed).

**Tech Stack:** Swift 5 + SwiftUI, EventKit (already in app), Foundation `URLSession`, macOS Keychain via existing `KeychainHelper`. Same "no SwiftPM packages" rule as the rest of the project.

---

## Conventions used in this plan

- All new files live under `MeetingReminder/Services/CalendarNotionSync/` and `MeetingReminder/Views/` for the Settings UI.
- New Keychain key: `notionCalendarSyncToken` (separate from `notionAPIToken`).
- New `UserDefaults` keys: `calendarNotionSyncEnabled` (Bool, default false), `calendarNotionSyncLastRunAt` (Date?), `calendarNotionSyncLastResult` (String, summary line).
- All upserts target the **data source ID**, not the database ID (Notion `2025-09-03` API).
- Log file location: `~/Library/Logs/MeetingReminder/calendar-notion-sync.log` (rotating 5 MB).

## Live IDs (do not regenerate, hardcoded as constants)

| Item | ID |
|------|----|
| Calendar Events data source | `1d605620-3b70-47f1-96d8-465e57fd0bdd` |
| Skip List data source | `77164bfd-8536-4c3a-ba3d-701fe64fc9b3` |

Constants live in `Services/CalendarNotionSync/CalendarSyncConstants.swift`. Not user-configurable — these are live and stable.

## Why a separate Notion token from the existing `NotionService`

The existing `NotionService` token is for the user-chosen "create meeting page" database. The Calendar Events / Skip List databases live under the Operations parent page and use a *different* integration scope (the user explicitly said the previous token was rotated and a new internal integration needs to be created and granted access to Operations). Mixing them risks the user accidentally pointing the create-meeting flow at the Calendar Events DS, or losing access to one when re-scoping the other. Cleaner: two tokens, two keychain entries, two settings tabs. Tiny duplication, much less footgun.

---

## Task 1: Read & familiarise

Before writing code, read these files end-to-end (no edits):

- `MeetingReminder/Services/CalendarService.swift` — EventKit access pattern, `events(matching:)` predicate.
- `MeetingReminder/Services/NotionService.swift` — `URLSession` patterns, Notion 2025-09-03 versioning, error handling.
- `MeetingReminder/Services/KeychainHelper.swift` — exact API to mirror.
- `MeetingReminder/Views/SettingsView.swift` — tab structure (we'll add an 8th tab).
- `MeetingReminder/MeetingReminderApp.swift` — where services get instantiated and stored.

No commit. This is just reading.

---

## Task 2: Hardcoded constants & shared types

**Files:**
- Create: `MeetingReminder/Services/CalendarNotionSync/CalendarSyncConstants.swift`

```swift
import Foundation

enum CalendarSyncConstants {
    static let calendarEventsDataSourceID = "1d605620-3b70-47f1-96d8-465e57fd0bdd"
    static let skipListDataSourceID = "77164bfd-8536-4c3a-ba3d-701fe64fc9b3"
    static let notionVersion = "2025-09-03"
    static let tokenKeychainKey = "notionCalendarSyncToken"
    static let internalDomain = "altra.cloud"
    static let lookbackDays = 90
    static let lookaheadDays = 30
    static let dailyHour = 6
    static let dailyMinute = 0
    static let logRelativePath = "Library/Logs/MeetingReminder/calendar-notion-sync.log"
    static let logMaxBytes = 5 * 1024 * 1024
    static let exchangeCalendarTitle = "Calendar"
    static let exchangeSourceTitle = "Exchange"
}
```

Add this file to `MeetingReminder.xcodeproj/project.pbxproj` (PBXFileReference + PBXBuildFile + group children + Sources phase) — same drill as adding any new Swift file. Build to confirm the project compiles.

**Commit:** `calsync: hardcoded constants for Notion DS IDs and tuning`

---

## Task 3: Rotating logger

**Files:**
- Create: `MeetingReminder/Services/CalendarNotionSync/CalendarSyncLogger.swift`

A small file logger scoped to this feature. Don't reuse `print` because we want a persistent on-disk audit trail the user can `tail -f`.

```swift
import Foundation

final class CalendarSyncLogger {
    enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    private let path: String
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "calendar-notion-sync.log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(path: String = CalendarSyncLogger.defaultPath, maxBytes: Int = CalendarSyncConstants.logMaxBytes) {
        self.path = path
        self.maxBytes = maxBytes
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(CalendarSyncConstants.logRelativePath)
    }

    func debug(_ s: String) { write(.debug, s) }
    func info(_ s: String)  { write(.info, s) }
    func warn(_ s: String)  { write(.warn, s) }
    func error(_ s: String) { write(.error, s) }

    func flush() { queue.sync { } }

    private func write(_ level: Level, _ message: String) {
        queue.async { [self] in
            rotateIfNeeded()
            let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            if let h = FileHandle(forWritingAtPath: path) {
                defer { try? h.close() }
                try? h.seekToEnd()
                if let data = line.data(using: .utf8) { try? h.write(contentsOf: data) }
            }
        }
    }

    private func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int,
              size >= maxBytes else { return }
        let rotated = path + ".1"
        try? FileManager.default.removeItem(atPath: rotated)
        try? FileManager.default.moveItem(atPath: path, toPath: rotated)
    }
}
```

No tests — this is plumbing. Sanity-check by writing a few lines from a one-shot menu bar action later.

**Commit:** `calsync: rotating file logger`

---

## Task 4: Pure-data event protocol & mapper

**Files:**
- Create: `MeetingReminder/Services/CalendarNotionSync/EventLike.swift`
- Create: `MeetingReminder/Services/CalendarNotionSync/CalendarEventMapper.swift`

This is the riskiest, detail-heaviest code. Keep it pure (no EventKit imports) so it can be unit-tested with synthetic stubs.

**`EventLike.swift`:**

```swift
import Foundation

protocol EventLike {
    var title: String { get }
    var startDate: Date { get }
    var endDate: Date { get }
    var isAllDay: Bool { get }
    /// EKEventStatus rawValue: 0=none, 1=confirmed, 2=tentative, 3=canceled
    var statusRawValue: Int { get }
    var organizerName: String? { get }
    var organizerEmail: String? { get }
    var attendees: [(name: String?, email: String)] { get }
    var location: String? { get }
    var notes: String? { get }
    var hasRecurrenceRules: Bool { get }
    var calendarItemExternalIdentifier: String { get }
}
```

**`CalendarEventMapper.swift`:** functions (all `static`, all pure):

- `compositeAppleID(for:) -> String` — non-recurring → bare external ID; recurring → `external + "_" + YYYY-MM-DD` where the date is rendered in **Europe/London** local time of `startDate`.
- `derivedStatus(for:now:) -> String` — `"Cancelled"` (statusRawValue == 3) > `"Today"` (Europe/London calendar day equality) > `"Upcoming"` (start > now) > `"Past"`.
- `attendeesString(for:) -> String` — pipe-separated `"Name <email>"`, organiser excluded by email match. Truncate at 1900 chars, cutting at the last `|` boundary, suffix `…`.
- `attendeeCount(for:) -> Int` — count excluding organiser by email match.
- `hasExternalAttendees(for:) -> Bool` — any non-organiser email whose domain (case-insensitive) is not `altra.cloud`.
- `extractConferenceURL(from:) -> String?` — scan `location` first then `notes`. Regex pattern: `https?://[^\s)>"']*(teams\.microsoft\.com|zoom\.us|meet\.google\.com|webex\.com)[^\s)>"']*`. Return first match or nil.
- `truncate(_:to:) -> String` — char-based truncation.

The big one:

- `expandToRows(events:now:) -> [(EventLike, isSeriesMaster: Bool)]`:
  1. Filter out cancelled (`statusRawValue == 3`).
  2. Group recurring events by `calendarItemExternalIdentifier`.
  3. For each group, emit one synthetic series-master row (using the first occurrence's metadata, with `compositeAppleID` overridden to be the bare external ID) followed by every occurrence.
  4. Non-recurring events pass through with `isSeriesMaster: false`.

The "synthetic series master" needs to be representable through `EventLike`. Easiest: define a concrete struct `SyntheticEvent: EventLike` that mirrors all fields, and synthesise it from the first occurrence. Then return `[(EventLike, Bool)]`.

**Tests:** add a new test target if the project doesn't already have one. If the project has no tests (check first), put tests in a new SwiftPM-style folder:

- Create: `MeetingReminderTests/CalendarSyncTests/CalendarEventMapperTests.swift`

(If there's no XCTest test target wired up yet, this needs an Xcode test-target setup as a sub-task — see Task 4a.)

**Required test cases (minimum):**

```swift
func testCompositeIDForNonRecurringIsBareExternalID()
func testCompositeIDForRecurringAppendsLondonDate_normal()
func testCompositeIDForRecurringHandlesBSTBoundary() // 23:30 UTC on 2026-04-28 → 00:30 BST on 2026-04-29 → suffix "_2026-04-29"
func testDerivedStatusCancelledWinsOverFutureDate()
func testDerivedStatusTodayMatchesLondonCalendarDay()
func testDerivedStatusUpcomingForFutureNonToday()
func testDerivedStatusPastForBeforeNow()
func testAttendeesStringExcludesOrganiserByEmail()
func testAttendeesStringTruncatesAt1900AtPipeBoundary()
func testAttendeeCountExcludesOrganiser()
func testHasExternalAttendeesFalseForAllInternal()
func testHasExternalAttendeesTrueForOneExternal()
func testHasExternalAttendeesIgnoresOrganiserDomain()
func testExtractConferenceURLPicksFirstMatchInNotes()
func testExtractConferenceURLPrefersLocationOverNotes()
func testExtractConferenceURLReturnsNilWhenAbsent()
func testExpandToRowsEmitsOneMasterPerRecurringSeries()
func testExpandToRowsSkipsCancelledOccurrences()
func testExpandToRowsPassesThroughNonRecurring()
```

Each test: red, then green. Commit after each logical group (maybe 4 commits across this task).

**Commit cadence:**
- `calsync: EventLike protocol`
- `calsync: composite Apple Event ID with Europe/London date suffix`
- `calsync: derived status / attendee helpers / conference URL extraction`
- `calsync: expand recurring series into master + occurrences`

### Task 4a (only if needed): wire up XCTest target

If `MeetingReminder.xcodeproj` has no test target, add one named `MeetingReminderTests`, link it against `MeetingReminder` (with `@testable import MeetingReminder`), and confirm `Cmd+U` runs zero tests successfully. Then proceed.

---

## Task 5: EKEvent → EventLike adapter

**Files:**
- Create: `MeetingReminder/Services/CalendarNotionSync/EKEvent+EventLike.swift`

```swift
import EventKit

extension EKEvent: EventLike {
    var statusRawValue: Int { Int(self.status.rawValue) }
    var organizerName: String? { self.organizer?.name }
    var organizerEmail: String? {
        guard let url = self.organizer?.url, url.scheme == "mailto" else { return nil }
        return url.absoluteString.replacingOccurrences(of: "mailto:", with: "").lowercased()
    }
    var attendees: [(name: String?, email: String)] {
        (self.attendees ?? []).compactMap { p in
            guard let url = p.url as URL?, url.scheme == "mailto" else { return nil }
            let email = url.absoluteString.replacingOccurrences(of: "mailto:", with: "").lowercased()
            return (p.name, email)
        }
    }
    var hasRecurrenceRules: Bool { (self.recurrenceRules ?? []).isEmpty == false }
}
```

Note: `EKEvent` already has `title`, `startDate`, `endDate`, `isAllDay`, `location`, `notes`, `calendarItemExternalIdentifier` matching the protocol's expected shapes. Confirm the `calendarItemExternalIdentifier` property is non-optional in our deployment target — if it's optional, adapt the protocol or coalesce with `""`.

**Commit:** `calsync: EKEvent adapter to EventLike`

---

## Task 6: Calendar resolver

**Files:**
- Modify: `MeetingReminder/Services/CalendarService.swift` — add a method (do not duplicate access logic).

Add to `CalendarService`:

```swift
func resolveExchangeCalendar() -> EKCalendar? {
    let candidates = eventStore.calendars(for: .event).filter {
        $0.title == CalendarSyncConstants.exchangeCalendarTitle &&
        $0.source.title == CalendarSyncConstants.exchangeSourceTitle
    }
    guard !candidates.isEmpty else { return nil }
    if candidates.count == 1 { return candidates[0] }
    let now = Date()
    let from = Calendar.current.date(byAdding: .day, value: -30, to: now)!
    return candidates.max(by: { a, b in
        let p1 = eventStore.predicateForEvents(withStart: from, end: now, calendars: [a])
        let p2 = eventStore.predicateForEvents(withStart: from, end: now, calendars: [b])
        return eventStore.events(matching: p1).count < eventStore.events(matching: p2).count
    })
}

func fetchEventsForSync(in calendar: EKCalendar) -> [EKEvent] {
    eventStore.refreshSourcesIfNecessary()
    let now = Date()
    let from = Calendar.current.date(byAdding: .day, value: -CalendarSyncConstants.lookbackDays, to: now)!
    let to   = Calendar.current.date(byAdding: .day, value:  CalendarSyncConstants.lookaheadDays, to: now)!
    let p = eventStore.predicateForEvents(withStart: from, end: to, calendars: [calendar])
    return eventStore.events(matching: p)
}
```

`eventStore` is already a private property of `CalendarService`. Caching the calendar identifier is unnecessary inside the app — it's a few-millisecond filter we run once per sync, and the user already grants Calendar access at app launch.

**Commit:** `calsync: CalendarService.resolveExchangeCalendar + fetchEventsForSync`

---

## Task 7: Notion HTTP client (scoped, with backoff)

**Files:**
- Create: `MeetingReminder/Services/CalendarNotionSync/CalendarSyncNotionClient.swift`

We deliberately do NOT extend the existing `NotionService` — its concerns are different (it owns observable UI state for the create-meeting flow). This client is a pure HTTP wrapper with retry logic, owned by the sync service.

```swift
import Foundation

struct CalendarSyncNotionError: Error, CustomStringConvertible {
    let status: Int
    let body: String
    var description: String { "Notion API \(status): \(body)" }
}

final class CalendarSyncNotionClient {
    private let token: String
    private let session: URLSession
    private let logger: CalendarSyncLogger

    init(token: String, logger: CalendarSyncLogger) {
        self.token = token
        self.logger = logger
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        try await request(method: "POST", path: path, body: body)
    }

    func patch(path: String, body: [String: Any]) async throws -> [String: Any] {
        try await request(method: "PATCH", path: path, body: body)
    }

    private func request(method: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        let url = URL(string: "https://api.notion.com/v1\(path)")!
        var attempt = 0
        var delay: UInt64 = 500_000_000

        while true {
            attempt += 1
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(CalendarSyncConstants.notionVersion, forHTTPHeaderField: "Notion-Version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }

            let (data, resp) = try await session.data(for: req)
            let http = resp as! HTTPURLResponse
            if (200..<300).contains(http.statusCode) {
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            let retriable = [429, 502, 503, 504].contains(http.statusCode)
            if retriable && attempt < 3 {
                logger.warn("notion \(http.statusCode), retrying (attempt \(attempt))")
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            }
            throw CalendarSyncNotionError(status: http.statusCode, body: bodyStr)
        }
    }
}
```

**Commit:** `calsync: scoped Notion HTTP client with backoff`

---

## Task 8: Notion query helpers

**Files:**
- Create: `MeetingReminder/Services/CalendarNotionSync/CalendarSyncNotionQueries.swift`

Two paginated queries: skip rules + existing events map. Same shape as the previous draft.

```swift
import Foundation

struct SkipRule {
    enum MatchType { case exactTitle, titleContains }
    let title: String
    let matchType: MatchType
}

enum CalendarSyncNotionQueries {
    static func fetchSkipRules(client: CalendarSyncNotionClient) async throws -> [SkipRule] {
        var rules: [SkipRule] = []
        var cursor: String? = nil
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let c = cursor { body["start_cursor"] = c }
            let resp = try await client.post(
                path: "/data_sources/\(CalendarSyncConstants.skipListDataSourceID)/query",
                body: body)
            let results = resp["results"] as? [[String: Any]] ?? []
            for row in results {
                guard let props = row["properties"] as? [String: Any] else { continue }
                let active = (props["Active"] as? [String: Any])?["checkbox"] as? Bool ?? true
                if !active { continue }
                let title = extractTitle(props["Meeting Title"]) ?? ""
                let mtRaw = ((props["Match Type"] as? [String: Any])?["select"] as? [String: Any])?["name"] as? String ?? "Exact Title"
                let mt: SkipRule.MatchType = (mtRaw == "Title Contains") ? .titleContains : .exactTitle
                if !title.isEmpty { rules.append(SkipRule(title: title, matchType: mt)) }
            }
            cursor = resp["next_cursor"] as? String
        } while cursor != nil
        return rules
    }

    static func fetchExistingEvents(client: CalendarSyncNotionClient) async throws -> [String: String] {
        var map: [String: String] = [:]
        var cursor: String? = nil
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let c = cursor { body["start_cursor"] = c }
            let resp = try await client.post(
                path: "/data_sources/\(CalendarSyncConstants.calendarEventsDataSourceID)/query",
                body: body)
            let results = resp["results"] as? [[String: Any]] ?? []
            for row in results {
                guard let id = row["id"] as? String,
                      let props = row["properties"] as? [String: Any],
                      let appleID = extractRichText(props["Apple Event ID"]),
                      !appleID.isEmpty else { continue }
                map[appleID] = id
            }
            cursor = resp["next_cursor"] as? String
        } while cursor != nil
        return map
    }

    private static func extractTitle(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let arr = dict["title"] as? [[String: Any]] else { return nil }
        return arr.compactMap { ($0["plain_text"] as? String) }.joined()
    }

    private static func extractRichText(_ any: Any?) -> String? {
        guard let dict = any as? [String: Any],
              let arr = dict["rich_text"] as? [[String: Any]] else { return nil }
        return arr.compactMap { ($0["plain_text"] as? String) }.joined()
    }
}
```

**Commit:** `calsync: Notion query helpers (skip rules, existing-events map)`

---

## Task 9: Skip filter

**Files:**
- Create: `MeetingReminder/Services/CalendarNotionSync/SkipFilter.swift`
- Create: `MeetingReminderTests/CalendarSyncTests/SkipFilterTests.swift`

```swift
enum SkipFilter {
    static func shouldSkip(title: String, rules: [SkipRule]) -> Bool {
        for rule in rules {
            switch rule.matchType {
            case .exactTitle: if title == rule.title { return true }
            case .titleContains: if title.range(of: rule.title, options: .caseInsensitive) != nil { return true }
            }
        }
        return false
    }
}
```

Tests: exact match case-sensitive, contains case-insensitive, mixed-rule list, no rules → false, empty title → false.

**Commit:** `calsync: skip-rule filter with tests`

---

## Task 10: Notion property builders

**Files:**
- Create: `MeetingReminder/Services/CalendarNotionSync/PropertyBuilder.swift`

```swift
import Foundation

enum PropertyBuilder {
    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let allDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        return f
    }()

    static func title(_ s: String) -> [String: Any] {
        ["title": [["text": ["content": String(s.prefix(2000))]]]]
    }
    static func richText(_ s: String) -> [String: Any] {
        ["rich_text": [["text": ["content": String(s.prefix(2000))]]]]
    }
    static func date(start: Date, end: Date, allDay: Bool) -> [String: Any] {
        let s = allDay ? allDayFormatter.string(from: start) : isoFormatter.string(from: start)
        let e = allDay ? allDayFormatter.string(from: end)   : isoFormatter.string(from: end)
        return ["date": ["start": s, "end": e]]
    }
    static func checkbox(_ b: Bool) -> [String: Any] { ["checkbox": b] }
    static func selectByName(_ name: String) -> [String: Any] { ["select": ["name": name]] }
    static func number(_ n: Int) -> [String: Any] { ["number": n] }
    static func url(_ u: String?) -> [String: Any] {
        if let u, !u.isEmpty { return ["url": u] }
        return ["url": NSNull()]
    }
    static func dateNow() -> [String: Any] { ["date": ["start": isoFormatter.string(from: Date())]] }
}
```

Plus an extension on `CalendarEventMapper` (or a separate `EventToNotionProperties.swift`) that composes the full property dict given `(EventLike, isSeriesMaster: Bool, now: Date)`. Properties to include — all column names verbatim from the brief:

- `Title` — `title`
- `Date` — `date(start, end, allDay:isAllDay)`
- `All Day` — `checkbox(isAllDay)`
- `Status` — `selectByName(derivedStatus)`
- `Calendar` — `selectByName("Calendar (Exchange)")`
- `Organiser` — `richText(organizerName ?? "")`
- `Attendees` — `richText(attendeesString)`
- `Attendee Count` — `number(attendeeCount)`
- `Has External Attendees` — `checkbox(hasExternalAttendees)`
- `Location` — `richText(location ?? "")`
- `Conference URL` — `url(extractConferenceURL)`
- `Description` — `richText(notes ?? "")` (truncated by `richText`)
- `Recurring` — `checkbox(hasRecurrenceRules)` (use the *original* event's flag for occurrences, true for synthetic masters)
- `Series Master` — `checkbox(isSeriesMaster)`
- `Apple Event ID` — `richText(compositeAppleID OR bare external for masters)`
- `iCal UID` — `richText(calendarItemExternalIdentifier)`
- `Last Synced` — `dateNow()`

Do NOT include `Meeting Notes` or `Pre-Call Briefing` properties at all — never write them.

**Commit:** `calsync: Notion property builders + event-to-properties composer`

---

## Task 11: Upsert engine

**Files:**
- Create: `MeetingReminder/Services/CalendarNotionSync/CalendarSyncUpserter.swift`

Combines everything. Takes `[(EventLike, isSeriesMaster)]`, the `existing` map, and a `dryRun` flag. Returns a `Counts` struct.

```swift
struct CalendarSyncCounts: CustomStringConvertible {
    var created = 0, updated = 0, skipped = 0, failed = 0
    var description: String {
        "created=\(created) updated=\(updated) skipped=\(skipped) failed=\(failed)"
    }
}

final class CalendarSyncUpserter {
    let client: CalendarSyncNotionClient
    let logger: CalendarSyncLogger
    let dryRun: Bool

    init(client: CalendarSyncNotionClient, logger: CalendarSyncLogger, dryRun: Bool) {
        self.client = client; self.logger = logger; self.dryRun = dryRun
    }

    func run(rows: [(event: EventLike, isSeriesMaster: Bool)],
             existing: [String: String]) async -> CalendarSyncCounts {
        var counts = CalendarSyncCounts()
        let now = Date()
        for row in rows {
            let appleID = row.isSeriesMaster
                ? row.event.calendarItemExternalIdentifier
                : CalendarEventMapper.compositeAppleID(for: row.event)
            let props = CalendarEventMapper.buildProperties(for: row.event,
                                                            now: now,
                                                            isSeriesMaster: row.isSeriesMaster)
            do {
                if let pageID = existing[appleID] {
                    if dryRun {
                        logger.info("DRY UPDATE \(appleID) :: \(row.event.title)")
                    } else {
                        _ = try await client.patch(path: "/pages/\(pageID)", body: ["properties": props])
                    }
                    counts.updated += 1
                } else {
                    if dryRun {
                        logger.info("DRY CREATE \(appleID) :: \(row.event.title)")
                    } else {
                        _ = try await client.post(path: "/pages", body: [
                            "parent": ["type": "data_source_id",
                                       "data_source_id": CalendarSyncConstants.calendarEventsDataSourceID],
                            "properties": props,
                        ])
                    }
                    counts.created += 1
                }
            } catch {
                logger.error("upsert failed for \(appleID): \(error)")
                counts.failed += 1
            }
        }
        return counts
    }
}
```

**Commit:** `calsync: upsert engine`

---

## Task 12: The orchestrator service

**Files:**
- Create: `MeetingReminder/Services/CalendarNotionSync/CalendarNotionSyncService.swift`

`@MainActor ObservableObject` so SwiftUI views can bind to it. Holds:

- `@Published var isRunning: Bool`
- `@Published var lastResult: String?` (mirrors UserDefaults, displayed in Settings)
- `@Published var lastRunAt: Date?` (mirrors UserDefaults)
- A reference to the existing `CalendarService`
- A `CalendarSyncLogger`
- A `Timer` for the daily 06:00 schedule

Public API:

```swift
@MainActor
final class CalendarNotionSyncService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var lastResult: String? = UserDefaults.standard.string(forKey: "calendarNotionSyncLastResult")
    @Published var lastRunAt: Date? = UserDefaults.standard.object(forKey: "calendarNotionSyncLastRunAt") as? Date

    private let calendarService: CalendarService
    private let logger = CalendarSyncLogger()
    private var dailyTimer: Timer?

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
    }

    var token: String? { KeychainHelper.read(key: CalendarSyncConstants.tokenKeychainKey) }
    var isConfigured: Bool { token != nil }
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "calendarNotionSyncEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "calendarNotionSyncEnabled"); rescheduleDaily() }
    }

    func storeToken(_ value: String) -> Bool { KeychainHelper.save(key: CalendarSyncConstants.tokenKeychainKey, value: value) }
    func clearToken() { KeychainHelper.delete(key: CalendarSyncConstants.tokenKeychainKey) }

    func startScheduleIfEnabled() { rescheduleDaily() }

    func runNow(dryRun: Bool = false) async {
        guard !isRunning else { logger.warn("run skipped: already running"); return }
        guard let token else { logger.error("no token configured"); updateLastResult("no token"); return }
        guard let cal = calendarService.resolveExchangeCalendar() else {
            logger.error("Exchange calendar not found"); updateLastResult("calendar not found"); return
        }
        isRunning = true
        defer { isRunning = false }

        logger.info("=== sync start (dryRun=\(dryRun)) ===")
        let client = CalendarSyncNotionClient(token: token, logger: logger)
        do {
            let skipRules = try await CalendarSyncNotionQueries.fetchSkipRules(client: client)
            logger.info("skip rules: \(skipRules.count)")

            let events = calendarService.fetchEventsForSync(in: cal)
            logger.info("ek events: \(events.count)")

            var skipped = 0
            let kept = events.filter { e in
                if SkipFilter.shouldSkip(title: e.title ?? "", rules: skipRules) { skipped += 1; return false }
                return true
            }

            let rows = CalendarEventMapper.expandToRows(events: kept, now: Date())
            let existing = try await CalendarSyncNotionQueries.fetchExistingEvents(client: client)
            logger.info("existing notion rows: \(existing.count); rows to upsert: \(rows.count)")

            let upserter = CalendarSyncUpserter(client: client, logger: logger, dryRun: dryRun)
            var counts = await upserter.run(rows: rows.map { ($0.0, $0.1) }, existing: existing)
            counts.skipped = skipped
            let summary = (dryRun ? "DRY: " : "") + counts.description
            logger.info("done — \(summary)")
            updateLastResult(summary)
        } catch {
            logger.error("fatal: \(error)")
            updateLastResult("error: \(error)")
        }
        logger.flush()
    }

    private func updateLastResult(_ s: String) {
        let now = Date()
        lastResult = s
        lastRunAt = now
        UserDefaults.standard.set(s, forKey: "calendarNotionSyncLastResult")
        UserDefaults.standard.set(now, forKey: "calendarNotionSyncLastRunAt")
    }

    private func rescheduleDaily() {
        dailyTimer?.invalidate()
        dailyTimer = nil
        guard isEnabled else { return }

        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = CalendarSyncConstants.dailyHour
        comps.minute = CalendarSyncConstants.dailyMinute
        var next = cal.date(from: comps)!
        if next <= now { next = cal.date(byAdding: .day, value: 1, to: next)! }
        let interval = next.timeIntervalSince(now)
        dailyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.runNow()
                self?.rescheduleDaily()
            }
        }
        logger.info("scheduled next run at \(next)")
    }
}
```

(Note `KeychainHelper.delete` may not exist on the current helper — if it doesn't, add one in this same task.)

**Commit:** `calsync: orchestrator service with daily timer`

---

## Task 13: Wire the service into the app

**Files:**
- Modify: `MeetingReminder/MeetingReminderApp.swift`

Find where `CalendarService`, `MeetingMonitor`, etc. are instantiated. Add:

```swift
@StateObject private var calendarNotionSync: CalendarNotionSyncService
```

Initialise in the same `init()` block as the other services, passing the existing `calendarService`. Call `calendarNotionSync.startScheduleIfEnabled()` from the same place that calls `meetingMonitor.start()` (or equivalent app-launch hook).

Pass `calendarNotionSync` into `MenuBarView` and `SettingsView` via `@EnvironmentObject` or constructor injection — match the existing pattern (look at how `notionService` is wired).

**Commit:** `calsync: wire CalendarNotionSyncService into app`

---

## Task 14: Menu bar dropdown row

**Files:**
- Modify: `MeetingReminder/Views/MenuBarView.swift`

Add a row near the existing "Done with meeting" / Preview rows:

```swift
if calendarNotionSync.isConfigured {
    Button {
        Task { await calendarNotionSync.runNow() }
    } label: {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(calendarNotionSync.isRunning ? "Syncing calendar to Notion…" : "Sync calendar to Notion now")
            Spacer()
            if let last = calendarNotionSync.lastRunAt {
                Text(last, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    .disabled(calendarNotionSync.isRunning)
}
```

**Commit:** `calsync: menu bar dropdown trigger`

---

## Task 15: Settings tab

**Files:**
- Create: `MeetingReminder/Views/CalendarNotionSyncSettingsView.swift`
- Modify: `MeetingReminder/Views/SettingsView.swift` — add an 8th tab "Calendar → Notion".

The new view contains:

1. **Status section** — last run timestamp, last result string, "running…" indicator.
2. **Token section** — `SecureField` for the integration token, "Save" button (writes to Keychain), "Clear" button. Show ✅ "Token stored" if present.
3. **Enable toggle** — bound to `calendarNotionSync.isEnabled`. Subtitle: "Daily sync at 06:00 local time."
4. **Buttons row** — "Sync Now" (runs `runNow(dryRun: false)`), "Dry Run" (runs `runNow(dryRun: true)`), "Open Log" (opens the log file in Console.app via `NSWorkspace.shared.open`).
5. **Help text** at the bottom: "One-way sync from Apple Calendar (Exchange) → Notion Calendar Events database. Existing rows are updated, never deleted. Manual relations to Meeting Notes and Pre-Call Briefings are preserved."

Layout: form-style, matches the look of the existing tabs. No new icons needed beyond SF Symbols.

**Commit:** `calsync: Settings tab with token entry and manual triggers`

---

## Task 16: Apple Shortcut hook

The user's brief asks for a shell-callable trigger. Since the sync now runs in the always-on app, the hook is simply a custom URL scheme.

**Files:**
- Modify: `MeetingReminder/Info.plist` — register URL scheme `meetingreminder` (if not already registered).
- Modify: `MeetingReminder/MeetingReminderApp.swift` — handle `onOpenURL`.

```swift
.onOpenURL { url in
    guard url.scheme == "meetingreminder" else { return }
    if url.host == "calsync" {
        Task { await calendarNotionSync.runNow() }
    }
}
```

The Apple Shortcut is then a single "Open URL" action with `meetingreminder://calsync`. Document this in the Settings tab help text.

If a URL scheme already exists for this app, just add the new host. If you'd rather avoid the URL-scheme hop, an alternative is `defaults write com.meetingreminder.app calendarNotionSyncRunRequest <timestamp>` watched via a `UserDefaults` change observer — but URL schemes are simpler and more discoverable.

**Commit:** `calsync: meetingreminder://calsync URL hook for Apple Shortcuts`

---

## Task 17: README update

**Files:**
- Modify: `CLAUDE.md` — add a "Calendar → Notion sync" architecture section near the existing "Minutes CLI Integration" subsection, mirroring its tone.

Cover:

- What it does + scope (one-way, Exchange calendar only).
- Where the orchestrator lives (`CalendarNotionSyncService.swift`).
- Identity strategy (composite Apple Event ID: `external_id` for non-recurring, `external_id_YYYY-MM-DD` for recurring occurrences, bare `external_id` for synthetic series masters; date in Europe/London).
- Why a separate Notion token from `NotionService` (link to "Why a separate Notion token" reasoning above).
- Trigger paths: daily 06:00 timer, menu bar item, Settings buttons, `meetingreminder://calsync`.
- Log file location.
- "Things this deliberately does not do" — no deletion, no relation writes, no schema changes, no bidirectional sync.

**Commit:** `calsync: document Calendar → Notion sync in CLAUDE.md`

---

## Task 18: End-to-end verification

1. Build and deploy via the standard `killall MeetingReminder && cp …Debug/MeetingReminder.app /Applications/MeetingReminder.app && open` flow documented in `CLAUDE.md`.
2. Generate a Notion internal integration named `cloud.altra.calsync` at https://www.notion.so/profile/integrations, grant it access to the Operations parent page (`350ef850-f293-81e1-afb8-d9478f631977`).
3. Open Settings → Calendar → Notion → paste token → Save → Enable.
4. Click **Dry Run** → tail `~/Library/Logs/MeetingReminder/calendar-notion-sync.log` → confirm clear CREATE/UPDATE log lines, zero `failed`.
5. Click **Sync Now** → expect ~150-300 created rows in Notion.
6. Click **Sync Now** again → expect `created=0 updated=N failed=0` (idempotent).
7. Pick a recurring event in Notion (e.g. "Ben / Adam / Sandra Sync") — confirm one Series Master + one row per occurrence in the window.
8. Edit a meeting in Apple Calendar (move time by 30 min) → wait for Apple Calendar to sync from Exchange → click **Sync Now** → confirm the existing Notion row's Date updated, no duplicate.
9. Add a Skip List entry (`Title Contains` = "lunch", Active checked) → click **Sync Now** → confirm zero new "lunch" rows appear (existing ones stay — we don't delete).
10. Manually link one Calendar Events row in Notion to a Meeting Notes row → click **Sync Now** → confirm the relation is preserved.
11. Trigger via Apple Shortcut (or `open meetingreminder://calsync`) → tail log to see the run fire.
12. Wait for the next 06:00 (or temporarily set `dailyHour` to a near-future minute, rebuild, and observe) → confirm the scheduled run executes and reschedules.

Paste the final summary line from the log back to me as evidence.

---

## Status checkpoint — 2026-04-28 evening

**Current branch state: code compiles (`xcodebuild build` clean), but B3+B2 not yet verified end-to-end on a live sync.**

### Done in this session
- MVP (tasks 1–18) shipped + deployed.
- Token unified to single `notionAPIToken`.
- Rolling-week view auto-patcher (Task #14) — verified working: `rolling-week: patched view 350ef850-… to 2026-04-27 … 2026-05-03`.
- Edit menu added to AppDelegate (Cmd+X/C/V/A now works in Settings text fields).
- Cal Sync tab `.onAppear` re-pulls from UserDefaults; rolling-week field bound directly via custom Binding; "Paste from clipboard" button added.

### B3 — Schema migrations (in progress, not yet verified)
- Created Notion DB **Cal Sync Migrations** under Operations. DS ID `7590658a-f038-45c1-b6ca-d50b2421b0c4`. Schema: Migration ID (title), Applied At (date), Description (rich_text). Empty.
- Added `MeetingReminder/Services/CalendarSyncMigrations.swift` with `Migration` struct, `applyPending(client:logger:dryRun:)`, `ensureSelectColumn` helper.
- Registered migrations:
  - `001-add-sync-state-column` — adds Sync State select (Active/Stale/Orphaned) to Calendar Events DS.
  - `002-add-source-calendar-column` — adds Source Calendar select with seed option "Calendar (Exchange)".
- Wired into `CalendarNotionSyncService.runNow` *before* upserts. Failures abort the run. Dry-run logs without applying.
- Added DS ID constant `migrationsDataSourceID` in `CalendarSyncConstants`.
- Added Xcode project entries for `CalendarSyncMigrations.swift`.
- **Verification still needed**: trigger a real (non-dry) sync, confirm log says `migrations: applying 001-…` and `migrations: applying 002-…`, then confirm both columns appear in Notion's Calendar Events DB and both rows appear in Cal Sync Migrations DB.

### B2 — Archive orphans (in progress, not yet verified)
- Reshaped `CalendarSyncNotionQueries.fetchExistingEvents` return type to `[String: ExistingRow]` where `ExistingRow = (pageID: String, hasManualRelations: Bool)`. Captures whether `Meeting Notes` or `Pre-Call Briefing` relation is populated.
- Added `archived` and `staled` counters to `CalendarSyncCounts`.
- `CalendarSyncUpserter` now:
  - Tracks touched `appleEventID`s during upsert.
  - Sets `Sync State = "Active"` on every touched row.
  - On UPDATE, includes `archived: false` (auto-restore from a previous archive).
  - When `archiveOrphans` flag is true: after upsert, identifies rows in `existing.keys - touched`, classifies each:
    - has manual relations → PATCH `Sync State = Stale` only.
    - otherwise → PATCH `Sync State = Orphaned` + `archived: true`.
  - All orphan handling logs and is non-fatal (per-row).
- Added `prefArchiveOrphansKey` UserDefaults key, default false.
- Settings tab: new "Cleanup" section with `Archive orphaned rows` toggle.
- **Verification still needed**:
  1. Toggle "Archive orphaned rows" on in Settings.
  2. Click Sync Now. Confirm log shows `orphans: N rows in Notion not in source` (probably 0 right now since this is the same source corpus).
  3. Manually delete an event in Apple Calendar. Click Sync Now. Confirm that row in Notion is now `Sync State = Orphaned` and archived (hidden from default queries).
  4. Manually link a different event to a Meeting Note. Delete it from Apple Calendar. Confirm it becomes `Stale`, not archived.
  5. Restore the deleted event. Confirm next sync flips `Sync State` back to Active and `archived: false`.

### B4 — Multi-calendar (started, partial)
- Added `prefEnabledCalendarIDsKey = "calendarNotionSyncEnabledCalendarIDs"` UserDefaults key. **Nothing reads or writes it yet.**
- Migration #002 (above) adds the Source Calendar column. The seed option "Calendar (Exchange)" exists; Notion auto-creates new options when other calendar names are written.

### What's left for B4 — pick up here next session

1. Add `EventLike.sourceCalendarName: String` (computed from EKEvent.calendar.title) — or pass calendar name through the upsert pipeline as a separate parameter.
2. Modify `CalendarEventMapper.buildProperties` to write `Source Calendar` select property. Must accept the calendar name as input (purest path: extra parameter, since the synthetic series-master event reuses one occurrence's source).
3. Refactor `CalendarNotionSyncService.runNow`:
   - Resolve enabled calendars (read `prefEnabledCalendarIDsKey`; if empty, default to the single Exchange calendar — preserves v1 behaviour exactly).
   - Loop: for each enabled calendar, fetch + skip-filter + expand → accumulate `[(event, isMaster, sourceCalName)]`.
   - Run upserter against the union. Touched set is global → orphan detection sees all calendars.
4. `CalendarSyncReader`:
   - Keep `resolveExchangeCalendar()` for the fallback path.
   - Add `enabledCalendars(ids: [String]) -> [EKCalendar]` that resolves identifiers; missing IDs are dropped with a warning.
5. Settings tab: add a section "Calendars to sync" with one Toggle per `availableCalendars` (read from CalendarService). State is saved to `prefEnabledCalendarIDsKey`. Default: only the Exchange match is checked.
6. First-run backfill: existing rows have no `Source Calendar` set. They'll all be UPDATEd in the next run with whatever calendar name we now pass — that backfills naturally. No special migration needed.

### B1 — Auto-link Meeting Notes / Pre-Call Briefing (not started)

Plan from earlier in this doc still stands. Schema discovery (B1.1) is the first concrete step — query Meeting Notes DS (`1f2ef850-f293-80ba-a763-000bb894d2c0`) and Pre-Call Briefings DS (`656b2eff-7ea3-4730-91fe-104ff647f4e3`) to learn their actual property names before designing the matcher.

### Files changed in this session (uncommitted)
- `MeetingReminder/Services/CalendarSyncTypes.swift` — constants, prefArchiveOrphansKey, prefEnabledCalendarIDsKey, migrationsDataSourceID.
- `MeetingReminder/Services/CalendarNotionSyncService.swift` — ExistingRow, archiveOrphans flag, orphan processing, archived:false on UPDATE, Sync State writes, migration runner wired into runNow.
- `MeetingReminder/Services/CalendarSyncMigrations.swift` — **new file**, migration runner.
- `MeetingReminder/Views/SettingsView.swift` — Cleanup section, Archive orphans toggle, calendarSync tab `.onAppear`, direct-binding rolling-week field, Paste button.
- `MeetingReminder/MeetingReminderApp.swift` — Edit menu (Cut/Copy/Paste/Select All/Undo/Redo).
- `MeetingReminder.xcodeproj/project.pbxproj` — pbxproj entries for `CalendarSyncMigrations.swift`.
- `CLAUDE.md` — Cal Sync section additions (rolling-week, token-unified, etc.).

### Known build/runtime gotchas

- After Edit→Save in source, must run `xcodebuild clean build` (just `build` sometimes uses a stale cache, e.g. when a new file is added but existing source isn't recompiled).
- `MeetingReminder.debug.dylib` inside `MeetingReminder.app/Contents/MacOS/` is where Swift code lives in Debug builds — when verifying a feature shipped, `strings` against the dylib not the launcher binary.
- URL-scheme trigger `meetingreminder://calsync` is intermittent. Reliable trigger paths in priority order: (1) menu bar → "Sync calendar to Notion now", (2) Settings → Cal Sync → Sync Now, (3) `open -g -a /Applications/MeetingReminder.app meetingreminder://calsync` after a fresh `killall MeetingReminder` + `open -a` cycle.
- LSUIElement apps need an explicit Edit menu in NSApp.mainMenu for Cmd+V to work in TextFields. Already added.

---

## Original status (2026-04-28 update)

- **MVP shipped**: tasks 1–18 above are implemented, building, deployed, 71 tests passing.
- **Integration access — must be granted before first sync**: in Notion, share each of the following with the integration (or share the Operations parent page once and let access propagate):
  - **Calendar Events** — https://www.notion.so/3e29a605309846668c0ee82cace69d61 (DS `1d605620-3b70-47f1-96d8-465e57fd0bdd`)
  - **Skip List** — DS `77164bfd-8536-4c3a-ba3d-701fe64fc9b3`
  - **Meeting Notes** — DS `1f2ef850-f293-80ba-a763-000bb894d2c0` (read-only sufficient until Phase B1)
  - **Pre-Call Briefings** — DS `656b2eff-7ea3-4730-91fe-104ff647f4e3` (read-only sufficient until Phase B1)
- **Token unified**: collapsed to a single `notionAPIToken` Keychain entry shared with `NotionService` after the user extended the existing integration's permissions to cover the Operations subtree. The Cal Sync tab is now a consumer of credentials, not an owner. The "two tokens by design" rationale is **dropped**.
- **Newly in scope** (was previously "out of scope"): the next four phases below have been promoted from non-goals to planned work, intentionally **not yet implemented**. Each is independent and can ship in any order.

---

## Phase B1: Auto-link Meeting Notes & Pre-Call Briefing relations

**Goal:** When a Calendar Events row is upserted, *if* there's an existing `Meeting Notes` page or `Pre-Call Briefing` page in their respective databases that clearly corresponds to the same meeting, auto-set the relation. Manual links the user has already created must be preserved untouched.

**Why:** The user manually creates these relations today. As the corpus grows, manual linking is the bottleneck. Same-day-same-title pairing is unambiguous enough to automate.

**Tension:** The original plan deliberately said "never write these columns — they're manual user territory." That's still true for *clearing* or *overwriting* them. The automation we're adding is strictly **append-if-empty**: never touch a relation that's already populated.

### Identity strategy for matching

Two databases, two strategies:

| Source DS | Match rule | Notes |
|-----------|-----------|-------|
| Meeting Notes (`1f2ef850-f293-80ba-a763-000bb894d2c0`) | Notes page's `Date` (or `Created Date`) overlaps the event's London-day **and** notes title `localizedCaseInsensitiveContains` event title (or vice-versa) | Inspect the actual schema first — task B1.1. The plan should be revised once the real property names are known. |
| Pre-Call Briefings (`656b2eff-7ea3-4730-91fe-104ff647f4e3`) | Briefing's `Calendar Event` relation already pointing at this row's previous Notion ID, OR briefing's title equals event title for an event happening on briefing's `For Date` | Briefings are created *for* an event by the existing 07:00 task — they may already be self-linking, in which case this auto-link is a no-op. Verify before building. |

If multiple candidates match, **abort the link** for that event and log a warning. Better to leave it manual than guess wrong.

### Tasks

**B1.1 — Schema discovery (no code).** Run a one-off query against both data sources and document the actual property names and types. Update this section with the real schemas before writing any code.

**B1.2 — `RelationLinker.swift`.** New service that takes the upsert context (event, freshly-created/updated `notion_page_id`) and runs two queries: one against Meeting Notes, one against Pre-Call Briefings. Return `(meetingNotesPageID: String?, briefingPageID: String?)` or nil if ambiguous/absent.

**B1.3 — Append-only update path.** Before issuing the relation update, query the Calendar Events row to read its current `Meeting Notes` / `Pre-Call Briefing` relation arrays. **If non-empty, skip.** If empty, PATCH `properties` with the resolved relation. This is the load-bearing safety check — write a unit test that a non-empty manual link is never overwritten.

**B1.4 — Wire into `CalendarSyncUpserter`.** After each create/update, call `RelationLinker` with the resulting page ID. Failures here are non-fatal (log + continue) — the row already exists, the relation can be added next run.

**B1.5 — Settings toggle.** `autoLinkMeetingNotesEnabled` (Bool, default true). The user may want to flip this off if they prefer to keep linking strictly manual.

**B1.6 — Document and verify.** Manually link one event in Notion → confirm sync run does not overwrite. Delete the manual link → confirm next run re-creates it (since the relation is now empty). Add an "ambiguous match" event (two notes pages with the same title same day) → confirm both are skipped with a log warning.

**Estimated size:** ~1 day. Riskiest part is B1.1 (discovering actual schemas).

---

## Phase B2: Archive deleted/cancelled events

**Goal:** When an event that previously existed in Notion is deleted from Apple Calendar (or moved entirely outside the sync window), reflect that in Notion *without* destroying any user-created data — manual relations, custom rich-text annotations, etc.

**Why:** The current behaviour is that orphaned rows accumulate forever. After 6 months of use, the Calendar Events DB will be cluttered with stale "Past" rows the user can't easily distinguish from real events.

**Constraint (still load-bearing):** Never `archived: true` a row that has manual relations populated, even if the source disappeared. The user may have linked an important note to it.

### Approach

Add a new `Sync State` select column (option values: `Active` / `Stale` / `Orphaned`) — this is a **schema modification**, so it overlaps with Phase B3 below. Order matters: B3 first (or at least B3.1 — the schema discovery + add-column step), then B2.

Pipeline change inside `CalendarSyncUpserter.run`:

1. Track the set of `appleEventID`s touched this run.
2. After upserts, compute `orphans = existing.keys - touched - permanentlyKept`.
3. For each orphan, query the row to see:
   - Has manual relations populated? → set `Sync State = Stale` (visible signal, no archive). Log.
   - Otherwise → set `Sync State = Orphaned` AND `archived = true` via `PATCH /pages/{id}` with `"archived": true`. Log.
4. **Never delete.** `archived: true` is reversible via the Notion UI / API. Hard-deletion is not.

### Tasks

**B2.1 — Add `Sync State` select column** to Calendar Events DB (depends on B3.1).

**B2.2 — Track touched IDs** in `CalendarSyncUpserter`.

**B2.3 — Orphan detection + classification** — query the existing row, check relation properties, decide between `Stale` and `Orphaned`.

**B2.4 — `PATCH /pages/{id}` with `archived: true`** for the orphan branch. Test that an archived row stops appearing in `data_sources/{id}/query` with default filters.

**B2.5 — Counts.** Add `archived` and `staled` to `CalendarSyncCounts`. Log them in the summary line.

**B2.6 — Settings toggle.** `archiveOrphansEnabled` (Bool, default false — opt-in for the first month while we observe behaviour).

**B2.7 — Verification.** Delete a calendar event with no manual links → confirm it gets archived next run. Delete a calendar event WITH a manual Meeting Notes link → confirm it's marked `Stale`, not archived. Restore the calendar event → confirm next run un-archives (need a `archived: false` reset path).

**Estimated size:** ~1 day. Mostly mechanical; the un-archive-on-restore path is the tricky bit.

---

## Phase B3: Schema migrations from code

**Goal:** Allow the app to add or rename Notion columns to the Calendar Events DB programmatically, so future field additions (e.g. the `Sync State` column from Phase B2) don't require manual schema editing in the Notion UI.

**Why:** Manual schema edits are error-prone and undocumented — if the user is on a different device or hasn't read the changelog, the next sync silently fails to write the new property. Code-driven migrations are tracked, idempotent, and visible in git history.

**Trade-off:** Adds complexity. The current "schema is pre-built, never modify" stance is simple and correct *until* we want to add columns. Once we do, the cost of code-managed schema is amortised across all future column additions.

### Approach

Introduce a tiny migration runner:

- A `Migration` struct: `id: String, description: String, apply: (CalendarSyncNotionClient) async throws -> Void`.
- A `_calsync_migrations` page (rich-text) under the Operations parent that records applied migration IDs, one per line. Read on every run; only un-applied migrations are run.
- Migrations are append-only. Once applied, never re-run; once recorded, never deleted.

Each migration uses Notion's `databases/{id}.update` (note: in 2025-09-03, the equivalent is updating the data source with `properties` patches) to add/rename columns.

### Tasks

**B3.1 — Schema introspection helper.** New `CalendarSyncNotionMigrations.swift` that fetches the current data source, lists its property names, and exposes a function to add a new property of a given type.

**B3.2 — Migrations log.** Create the `_calsync_migrations` rich-text page under Operations. Read/append helpers.

**B3.3 — First migration: `add-sync-state-column-001`.** Adds the `Sync State` select column with three options (`Active`, `Stale`, `Orphaned`). Idempotent — checks existence first.

**B3.4 — Run-on-startup hook.** At the top of `CalendarNotionSyncService.runNow`, before any upserts, run `Migrations.applyPending(client:)`. Log each migration applied. Failure aborts the sync run with a clear error — better to refuse to sync against a half-migrated schema than to silently drop columns.

**B3.5 — Dry-run respect.** In dry-run mode, log the migrations that *would* run but don't apply them.

**B3.6 — Verification.** Run sync once → confirm `Sync State` column appears in Notion + log line says "applied add-sync-state-column-001". Run sync again → confirm migration is skipped. Manually delete the migration log entry → confirm next run re-applies (and a no-op idempotent migration succeeds).

**Estimated size:** ~1.5 days. The Notion API for column updates is undocumented in places — expect 30 minutes of trial-and-error per property type.

---

## Phase B4: Multi-calendar support

**Goal:** Sync more than one Apple Calendar to Notion. Currently hardcoded to the single Exchange "Calendar". User has signalled future calendars (personal Google, side-project iCloud, etc.) may want syncing too.

**Why:** Optionality. Today there's one calendar; tomorrow there may be three. Building multi-calendar in once is cheaper than retrofitting it.

**Constraint:** Each synced calendar must be a deliberate opt-in. Never silently sweep up *every* calendar EventKit knows about — that would include shared/subscribed calendars (holidays, sports schedules) that have no business landing in a personal ledger.

### Approach

Add a `Source Calendar` column to the Notion DB (handled via Phase B3 migration) — every row records which Apple calendar it came from. Use this to scope upsert / orphan-detection logic per-calendar.

`UserDefaults` stores an array of opted-in calendar identifiers: `calendarSyncEnabledCalendarIDs`. The Settings tab grows a multi-select list of all `EKCalendar`s, defaulting to *just* the Exchange one (preserves current behaviour). Each tick adds an ID to the array.

The sync loop iterates over each enabled calendar, fetches events with the same window, and upserts them. The upsert key is unchanged (composite Apple Event ID is globally unique across calendars — it's the Exchange UID), but the new `Source Calendar` column lets the user filter views per source.

### Tasks

**B4.1 — Schema migration `add-source-calendar-column-002`** (depends on Phase B3 — adds a select column populated with each calendar's display name).

**B4.2 — Settings UI** in the Cal Sync tab: a list of all EKCalendars with checkboxes. Default to checked: only the Exchange calendar matching the existing constants. Persist to `calendarSyncEnabledCalendarIDs`.

**B4.3 — Migrate existing rows.** First sync after enabling B4 should backfill `Source Calendar = "Calendar (Exchange)"` for every existing row that has it empty. One-time migration, log at run start.

**B4.4 — Per-calendar fetch + upsert** loop. Replace the single `resolveExchangeCalendar` call with iteration over enabled IDs.

**B4.5 — Per-calendar orphan detection.** When B2 ships, orphan detection must scope by `Source Calendar` — an event missing from Calendar A is not an orphan if it exists in Calendar B's predicate.

**B4.6 — Source-calendar-specific skip rules.** Optional Phase B4.7 enhancement: extend the Skip List schema (Phase B3 migration) with an optional `Calendar` column so a rule can scope to one source. Out of B4 unless explicitly asked.

**B4.7 — Verification.** Enable a second calendar in Settings → sync → confirm new rows appear with the correct `Source Calendar`. Delete an event from calendar A → confirm only that event is archived, not events from calendar B. Disable calendar A in Settings → sync → confirm no new rows from A, existing A rows untouched.

**Estimated size:** ~1.5 days. Hinges on B3 being done first (need the schema migration capability).

---

## Dependency order

```
B3 (migrations) ─┬─> B2 (archive)
                 └─> B4 (multi-calendar)

B1 (auto-link) — independent, can ship any time
```

Recommended sequence: **B3 → B2 → B4 → B1**. B3 unlocks safe schema growth, B2 stops the Notion DB from rotting, B4 generalises the source, and B1 polishes the relation UX once everything else is stable. B1 can also be done first if it's higher-value to the user — it has no schema dependencies.
