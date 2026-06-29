# Cal.com Mac Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Cal.com as the booking backend — new `CalComService` REST wrapper, `CalComSyncService` sync loop (replaces `BookingPollService`), and a Cal.com Settings tab for API management.

**Architecture:** `CalComService` wraps `https://api.cal.com/v2/` with the API key in Keychain (`calComAPIKey`). `CalComSyncService` polls Cal.com every 5 min + on wake, creates EKEvents tagged `[calcom-booking-id:<uid>]`. `CalComSettingsView` is a new Settings tab (10th tab) for connection, event type management, schedule viewing, and booking list. `BookingPollService` is gated — only runs when `calComAPIKey` is absent (legacy fallback).

**Tech Stack:** Swift 5 / SwiftUI / EventKit / URLSession / Keychain / macOS 13+

**pbxproj IDs (pre-assigned, globally unique):**
- `CalComModels.swift` → PBXBuildFile `A1000080`, PBXFileReference `B1000080`
- `CalComService.swift` → PBXBuildFile `A1000081`, PBXFileReference `B1000081`
- `CalComSyncService.swift` → PBXBuildFile `A1000082`, PBXFileReference `B1000082`
- `CalComSettingsView.swift` → PBXBuildFile `A1000083`, PBXFileReference `B1000083`

---

## Task 1: CalComModels.swift

**Files:**
- Create: `MeetingReminder/Models/CalComModels.swift`

**Step 1: Create the file**

```swift
import Foundation

// MARK: - Event Type

struct CalComEventType: Codable, Identifiable {
    let id: Int
    let title: String
    let slug: String
    let description: String?
    let lengthInMinutes: Int
    let lengthInMinutesOptions: [Int]?
    let minimumBookingNotice: Int
    let beforeEventBuffer: Int
    let afterEventBuffer: Int
    let hidden: Bool
    let bookingUrl: String?
    let bookingFields: [CalComBookingField]?
}

struct CalComBookingField: Codable, Identifiable {
    let slug: String
    let label: String?
    let type: String
    let required: Bool?
    let isDefault: Bool?
    let hidden: Bool?
    var id: String { slug }
}

struct CalComEventTypeInput: Codable {
    var title: String?
    var slug: String?
    var description: String?
    var lengthInMinutes: Int?
    var minimumBookingNotice: Int?
    var beforeEventBuffer: Int?
    var afterEventBuffer: Int?
    var hidden: Bool?
}

// MARK: - Schedule

struct CalComSchedule: Codable, Identifiable {
    let id: Int
    let name: String
    let timeZone: String
    let isDefault: Bool
    let availability: [CalComAvailabilityWindow]?
}

struct CalComAvailabilityWindow: Codable {
    let days: [String]
    let startTime: String
    let endTime: String
}

// MARK: - Booking

struct CalComBooking: Codable, Identifiable {
    let uid: String
    let title: String?
    let start: String
    let end: String
    let status: String
    let attendees: [CalComAttendee]?
    let location: String?
    let eventTypeId: Int?
    let metadata: [String: String]?
    var id: String { uid }

    var startDate: Date? { ISO8601DateFormatter().date(from: start) }
    var endDate: Date? { ISO8601DateFormatter().date(from: end) }
}

struct CalComAttendee: Codable {
    let name: String
    let email: String
    let timeZone: String?
}

// MARK: - API Response wrappers

struct CalComListResponse<T: Codable>: Codable {
    let status: String
    let data: [T]?
}

struct CalComSingleResponse<T: Codable>: Codable {
    let status: String
    let data: T?
}

// MARK: - Errors

enum CalComError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case httpError(Int, String)
    case decodingError(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:       return "Cal.com API key not configured"
        case .invalidURL:          return "Invalid Cal.com API URL"
        case .httpError(let c, let b): return "HTTP \(c)\(b.isEmpty ? "" : ": \(b)")"
        case .decodingError(let s): return "Decode error: \(s)"
        case .unauthorized:        return "Unauthorized — check your Cal.com API key"
        }
    }
}
```

**Step 2: Add to pbxproj**

In `MeetingReminder.xcodeproj/project.pbxproj`, add 4 entries:

*PBXBuildFile section* (near other `A100007x` entries):
```
		A1000080 /* CalComModels.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000080 /* CalComModels.swift */; };
```

*PBXFileReference section* (near other `B100007x` entries):
```
		B1000080 /* CalComModels.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CalComModels.swift; sourceTree = "<group>"; };
```

*Models group children* (find the Models group — look for `ChecklistItem.swift` nearby — and add):
```
				B1000080 /* CalComModels.swift */,
```

*Sources build phase* (find the Sources section with other `A100007x in Sources` entries):
```
				A1000080 /* CalComModels.swift in Sources */,
```

**Step 3: Build to verify**
```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project MeetingReminder.xcodeproj \
  -scheme MeetingReminder \
  -configuration Debug build 2>&1 | grep -E "error:|warning:|BUILD"
```
Expected: `BUILD SUCCEEDED`

**Step 4: Commit**
```bash
git add MeetingReminder/Models/CalComModels.swift MeetingReminder.xcodeproj/project.pbxproj
git commit -m "feat(calcom): add CalComModels Codable structs"
```

---

## Task 2: CalComService.swift

**Files:**
- Create: `MeetingReminder/Services/CalComService.swift`

**Step 1: Create the file**

```swift
import Foundation

/// REST wrapper around https://api.cal.com/v2/
/// API key stored in Keychain as `calComAPIKey`.
/// All methods throw CalComError on failure.
@MainActor
final class CalComService: ObservableObject {

    static let keychainKey = "calComAPIKey"
    private static let baseURL = "https://api.cal.com/v2"
    private static let eventTypeVersion = "2024-06-14"
    private static let bookingVersion = "2024-08-13"
    private static let scheduleVersion = "2024-06-11"

    // MARK: - Key management

    var apiKey: String? {
        KeychainHelper.read(key: Self.keychainKey)
    }

    var isConfigured: Bool {
        guard let k = apiKey else { return false }
        return !k.isEmpty
    }

    func saveAPIKey(_ key: String) {
        if key.isEmpty {
            KeychainHelper.delete(key: Self.keychainKey)
        } else {
            KeychainHelper.save(key: Self.keychainKey, value: key)
        }
    }

    func deleteAPIKey() {
        KeychainHelper.delete(key: Self.keychainKey)
    }

    // MARK: - Event Types

    func fetchEventTypes() async throws -> [CalComEventType] {
        let data = try await get(path: "/event-types", version: Self.eventTypeVersion)
        let resp = try decode(CalComListResponse<CalComEventType>.self, from: data)
        return resp.data ?? []
    }

    func updateEventType(id: Int, input: CalComEventTypeInput) async throws -> CalComEventType {
        let body = try JSONEncoder().encode(input)
        let data = try await patch(path: "/event-types/\(id)", version: Self.eventTypeVersion, body: body)
        let resp = try decode(CalComSingleResponse<CalComEventType>.self, from: data)
        guard let et = resp.data else { throw CalComError.decodingError("no data in response") }
        return et
    }

    // MARK: - Schedules

    func fetchSchedules() async throws -> [CalComSchedule] {
        let data = try await get(path: "/schedules", version: Self.scheduleVersion)
        let resp = try decode(CalComListResponse<CalComSchedule>.self, from: data)
        return resp.data ?? []
    }

    // MARK: - Bookings

    func fetchUpcomingBookings(after: Date? = nil) async throws -> [CalComBooking] {
        var query = "status[]=upcoming&take=50"
        if let after {
            let iso = ISO8601DateFormatter().string(from: after)
            query += "&afterStart=\(iso)"
        }
        let data = try await get(path: "/bookings?\(query)", version: Self.bookingVersion)
        let resp = try decode(CalComListResponse<CalComBooking>.self, from: data)
        return resp.data ?? []
    }

    func fetchPastBookings(limit: Int = 20) async throws -> [CalComBooking] {
        let data = try await get(path: "/bookings?status[]=past&take=\(limit)&sortStart=desc", version: Self.bookingVersion)
        let resp = try decode(CalComListResponse<CalComBooking>.self, from: data)
        return resp.data ?? []
    }

    func cancelBooking(uid: String, reason: String? = nil) async throws {
        var payload: [String: String] = [:]
        if let reason { payload["cancellationReason"] = reason }
        let body = try JSONEncoder().encode(payload)
        _ = try await delete(path: "/bookings/\(uid)", version: Self.bookingVersion, body: body)
    }

    // MARK: - Connection test

    func testConnection() async throws -> String {
        let types = try await fetchEventTypes()
        return "Connected — \(types.count) event type(s)"
    }

    // MARK: - HTTP helpers

    private func get(path: String, version: String) async throws -> Data {
        guard let key = apiKey else { throw CalComError.missingAPIKey }
        guard let url = URL(string: Self.baseURL + path) else { throw CalComError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "cal-api-version")
        return try await send(req)
    }

    private func patch(path: String, version: String, body: Data) async throws -> Data {
        guard let key = apiKey else { throw CalComError.missingAPIKey }
        guard let url = URL(string: Self.baseURL + path) else { throw CalComError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "cal-api-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await send(req)
    }

    private func delete(path: String, version: String, body: Data) async throws -> Data {
        guard let key = apiKey else { throw CalComError.missingAPIKey }
        guard let url = URL(string: Self.baseURL + path) else { throw CalComError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "cal-api-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await send(req)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalComError.invalidURL }
        if http.statusCode == 401 { throw CalComError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CalComError.httpError(http.statusCode, body)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CalComError.decodingError(error.localizedDescription)
        }
    }
}
```

**Step 2: Add to pbxproj** (same 4-entry pattern as Task 1)

*PBXBuildFile:*
```
		A1000081 /* CalComService.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000081 /* CalComService.swift */; };
```
*PBXFileReference:*
```
		B1000081 /* CalComService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CalComService.swift; sourceTree = "<group>"; };
```
*Services group children* (near `BookingPollService.swift`):
```
				B1000081 /* CalComService.swift */,
```
*Sources build phase:*
```
				A1000081 /* CalComService.swift in Sources */,
```

**Step 3: Build**
```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project MeetingReminder.xcodeproj \
  -scheme MeetingReminder \
  -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`

**Step 4: Commit**
```bash
git add MeetingReminder/Services/CalComService.swift MeetingReminder.xcodeproj/project.pbxproj
git commit -m "feat(calcom): add CalComService REST wrapper"
```

---

## Task 3: CalComSyncService.swift

**Files:**
- Create: `MeetingReminder/Services/CalComSyncService.swift`

**Step 1: Create the file**

```swift
import EventKit
import Foundation

/// Syncs Cal.com bookings → local EKEvents.
/// Polls every 5 min while awake + once on NSWorkspace wake notification.
/// Tags each created event with [calcom-booking-id:<uid>] for idempotency.
/// Replaces BookingPollService when calComAPIKey is set in Keychain.
@MainActor
final class CalComSyncService: ObservableObject {

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }
    @Published var lastSyncedAt: Date?
    @Published var lastSyncResult: String?
    @Published var lastError: String?

    private static let enabledKey = "calComSyncEnabled"
    private static let lastSyncKey = "calComLastSyncedAt"
    static let syncInterval: TimeInterval = 5 * 60

    private let calCom: CalComService
    private let eventStore: EKEventStore
    private var timer: Timer?
    private var wakeObserver: Any?
    private var isSyncing = false

    init(calCom: CalComService, eventStore: EKEventStore = EKEventStore()) {
        self.calCom = calCom
        self.eventStore = eventStore
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        guard isEnabled, calCom.isConfigured else { return }
        start()
    }

    func start() {
        stop()
        guard calCom.isConfigured else { return }

        Task { await syncOnce() }

        timer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncOnce() }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.syncOnce() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }

    // MARK: - Sync

    func syncOnce() async {
        guard calCom.isConfigured else {
            lastError = "Cal.com API key not configured"
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Look back 1 hour to catch bookings made while the Mac was asleep.
        let lookback = Date().addingTimeInterval(-3600)
        let lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        let after = lastSync.map { min($0, lookback) } ?? lookback

        do {
            let bookings = try await calCom.fetchUpcomingBookings(after: after)
            var synced = 0
            var skipped = 0

            for booking in bookings {
                let result = await syncBooking(booking)
                if result { synced += 1 } else { skipped += 1 }
            }

            lastSyncedAt = Date()
            UserDefaults.standard.set(lastSyncedAt, forKey: Self.lastSyncKey)
            lastSyncResult = "synced=\(synced) skipped=\(skipped)"
            lastError = nil

        } catch {
            lastError = error.localizedDescription
            lastSyncedAt = Date()
        }
    }

    /// Returns true if a new EKEvent was created, false if already existed.
    private func syncBooking(_ booking: CalComBooking) async -> Bool {
        guard let start = booking.startDate, let end = booking.endDate else { return false }
        let marker = "[calcom-booking-id:\(booking.uid)]"

        // Idempotency: check if we already created this event.
        if findTaggedEvent(marker: marker, near: start) != nil { return false }

        let title = booking.title ?? "Meeting"
        let attendeeLine = booking.attendees?.map { "\($0.name) <\($0.email)>" }.joined(separator: ", ") ?? ""
        let notes = [
            "Booked via Cal.com.",
            attendeeLine.isEmpty ? nil : "Attendee: \(attendeeLine)",
            booking.location.map { "Location: \($0)" },
            marker
        ].compactMap { $0 }.joined(separator: "\n")

        guard let calendar = eventStore.defaultCalendarForNewEvents else { return false }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = calendar

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return true
        } catch {
            NSLog("[CalComSync] failed to save event for booking \(booking.uid): \(error.localizedDescription)")
            return false
        }
    }

    private func findTaggedEvent(marker: String, near date: Date) -> EKEvent? {
        eventStore.refreshSourcesIfNecessary()
        let window = DateInterval(start: date.addingTimeInterval(-300), end: date.addingTimeInterval(300))
        let pred = eventStore.predicateForEvents(
            withStart: window.start,
            end: window.end,
            calendars: nil
        )
        return eventStore.events(matching: pred).first { $0.notes?.contains(marker) == true }
    }
}
```

**Step 2: Add to pbxproj**

*PBXBuildFile:*
```
		A1000082 /* CalComSyncService.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000082 /* CalComSyncService.swift */; };
```
*PBXFileReference:*
```
		B1000082 /* CalComSyncService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CalComSyncService.swift; sourceTree = "<group>"; };
```
*Services group children* (near `CalComService.swift`):
```
				B1000082 /* CalComSyncService.swift */,
```
*Sources build phase:*
```
				A1000082 /* CalComSyncService.swift in Sources */,
```

**Step 3: Gate BookingPollService**

In `MeetingReminder/Services/BookingPollService.swift`, add this guard at the top of `start()`:

```swift
func start() {
    // Legacy Supabase poll — disabled when Cal.com API key is configured.
    guard KeychainHelper.read(key: CalComService.keychainKey) == nil else { return }
    stop()
    guard isEnabled, isConfigured else { return }
    // ... rest of existing start() body unchanged
```

**Step 4: Wire into MeetingReminderApp.swift**

In `MeetingReminder/MeetingReminderApp.swift`:

Add property:
```swift
@StateObject private var calComService: CalComService
@StateObject private var calComSyncService: CalComSyncService
```

In `init()`, after `let bookingPoll = BookingPollService(graph: graphMail)`:
```swift
let calCom = CalComService()
let calComSync = CalComSyncService(calCom: calCom)
_calComService = StateObject(wrappedValue: calCom)
_calComSyncService = StateObject(wrappedValue: calComSync)
```

In the `.onAppear` / launch block (near `bookingPollService.start()`):
```swift
calComSyncService.startIfEnabled()
```

**Step 5: Build**
```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project MeetingReminder.xcodeproj \
  -scheme MeetingReminder \
  -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`

**Step 6: Commit**
```bash
git add MeetingReminder/Services/CalComSyncService.swift \
        MeetingReminder/Services/BookingPollService.swift \
        MeetingReminder/MeetingReminderApp.swift \
        MeetingReminder.xcodeproj/project.pbxproj
git commit -m "feat(calcom): add CalComSyncService + gate BookingPollService"
```

---

## Task 4: CalComSettingsView.swift

**Files:**
- Create: `MeetingReminder/Views/CalComSettingsView.swift`

**Step 1: Create the file**

```swift
import SwiftUI

struct CalComSettingsView: View {
    @ObservedObject var calComService: CalComService
    @ObservedObject var calComSyncService: CalComSyncService

    @State private var apiKeyDraft: String = ""
    @State private var isTestingConnection = false
    @State private var connectionStatus: String? = nil
    @State private var connectionOK = false

    @State private var eventTypes: [CalComEventType] = []
    @State private var isLoadingEventTypes = false

    @State private var schedules: [CalComSchedule] = []
    @State private var isLoadingSchedules = false

    @State private var upcomingBookings: [CalComBooking] = []
    @State private var isLoadingBookings = false
    @State private var cancellingUID: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                connectionSection
                if calComService.isConfigured {
                    syncSection
                    eventTypesSection
                    schedulesSection
                    bookingsSection
                }
            }
            .padding()
        }
        .onAppear { loadAPIKeyDraft(); if calComService.isConfigured { loadAll() } }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        GroupBox("Connection") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SecureField("API key (cal_live_...)", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { saveKey() }
                    if calComService.isConfigured {
                        Button("Disconnect", role: .destructive) { disconnect() }
                    }
                }
                HStack {
                    Button(isTestingConnection ? "Testing…" : "Test connection") {
                        Task { await testConnection() }
                    }
                    .disabled(apiKeyDraft.isEmpty || isTestingConnection)
                    if let status = connectionStatus {
                        Image(systemName: connectionOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(connectionOK ? .green : .red)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        GroupBox("Booking Sync") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Sync Cal.com bookings to Calendar (every 5 min + on wake)",
                       isOn: $calComSyncService.isEnabled)
                if let at = calComSyncService.lastSyncedAt {
                    Text("Last sync: \(at.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let result = calComSyncService.lastSyncResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
                if let err = calComSyncService.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Button("Sync now") { Task { await calComSyncService.syncOnce() } }
            }
            .padding(8)
        }
    }

    // MARK: - Event Types

    private var eventTypesSection: some View {
        GroupBox("Event Types") {
            VStack(alignment: .leading, spacing: 8) {
                if isLoadingEventTypes {
                    ProgressView()
                } else {
                    ForEach(eventTypes) { et in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(et.title).font(.headline)
                                Text("/\(et.slug) · \(et.lengthInMinutes) min")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let desc = et.description, !desc.isEmpty {
                                    Text(desc).font(.caption2).foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if et.hidden {
                                Text("Hidden").font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary).clipShape(Capsule())
                            }
                            if let url = et.bookingUrl, let u = URL(string: url) {
                                Link(destination: u) {
                                    Image(systemName: "arrow.up.right.square")
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        if et.id != eventTypes.last?.id {
                            Divider()
                        }
                    }
                }
                Button("Refresh") { Task { await loadEventTypes() } }
                    .font(.caption)
            }
            .padding(8)
        }
    }

    // MARK: - Schedules

    private var schedulesSection: some View {
        GroupBox("Schedules") {
            VStack(alignment: .leading, spacing: 8) {
                if isLoadingSchedules {
                    ProgressView()
                } else {
                    ForEach(schedules) { schedule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(schedule.name).font(.headline)
                                Text(schedule.timeZone).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if schedule.isDefault {
                                Text("Default").font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.blue.opacity(0.15)).clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Button("Refresh") { Task { await loadSchedules() } }
                    .font(.caption)
            }
            .padding(8)
        }
    }

    // MARK: - Bookings

    private var bookingsSection: some View {
        GroupBox("Upcoming Bookings") {
            VStack(alignment: .leading, spacing: 8) {
                if isLoadingBookings {
                    ProgressView()
                } else if upcomingBookings.isEmpty {
                    Text("No upcoming bookings").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(upcomingBookings) { booking in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(booking.title ?? "Meeting").font(.headline)
                                if let start = booking.startDate {
                                    Text(start.formatted(.dateTime.weekday().day().month().hour().minute()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let attendee = booking.attendees?.first {
                                    Text(attendee.name).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button("Cancel") {
                                Task { await cancel(uid: booking.uid) }
                            }
                            .disabled(cancellingUID == booking.uid)
                            .foregroundStyle(.red)
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                        if booking.uid != upcomingBookings.last?.uid { Divider() }
                    }
                }
                Button("Refresh") { Task { await loadBookings() } }
                    .font(.caption)
            }
            .padding(8)
        }
    }

    // MARK: - Actions

    private func loadAPIKeyDraft() {
        apiKeyDraft = calComService.apiKey ?? ""
    }

    private func saveKey() {
        calComService.saveAPIKey(apiKeyDraft)
        connectionStatus = nil
        if calComService.isConfigured { loadAll() }
    }

    private func disconnect() {
        calComService.deleteAPIKey()
        apiKeyDraft = ""
        eventTypes = []
        schedules = []
        upcomingBookings = []
        connectionStatus = nil
    }

    private func testConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }
        // Test using the draft key temporarily
        let saved = calComService.apiKey
        calComService.saveAPIKey(apiKeyDraft)
        do {
            let msg = try await calComService.testConnection()
            connectionStatus = msg
            connectionOK = true
        } catch {
            connectionStatus = error.localizedDescription
            connectionOK = false
            // Restore previous key if test fails
            if let prev = saved { calComService.saveAPIKey(prev) }
            else { calComService.deleteAPIKey() }
        }
        isTestingConnection = false
    }

    private func loadAll() {
        Task { await loadEventTypes() }
        Task { await loadSchedules() }
        Task { await loadBookings() }
    }

    private func loadEventTypes() async {
        isLoadingEventTypes = true
        defer { isLoadingEventTypes = false }
        do { eventTypes = try await calComService.fetchEventTypes() }
        catch { NSLog("[CalComSettings] eventTypes: \(error)") }
    }

    private func loadSchedules() async {
        isLoadingSchedules = true
        defer { isLoadingSchedules = false }
        do { schedules = try await calComService.fetchSchedules() }
        catch { NSLog("[CalComSettings] schedules: \(error)") }
    }

    private func loadBookings() async {
        isLoadingBookings = true
        defer { isLoadingBookings = false }
        do { upcomingBookings = try await calComService.fetchUpcomingBookings() }
        catch { NSLog("[CalComSettings] bookings: \(error)") }
    }

    private func cancel(uid: String) async {
        cancellingUID = uid
        defer { cancellingUID = nil }
        do {
            try await calComService.cancelBooking(uid: uid)
            upcomingBookings.removeAll { $0.uid == uid }
        } catch {
            NSLog("[CalComSettings] cancel \(uid): \(error)")
        }
    }
}
```

**Step 2: Add to pbxproj**

*PBXBuildFile:*
```
		A1000083 /* CalComSettingsView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000083 /* CalComSettingsView.swift */; };
```
*PBXFileReference:*
```
		B1000083 /* CalComSettingsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CalComSettingsView.swift; sourceTree = "<group>"; };
```
*Views group children* (near `BusyLightSettingsView.swift`):
```
				B1000083 /* CalComSettingsView.swift */,
```
*Sources build phase:*
```
				A1000083 /* CalComSettingsView.swift in Sources */,
```

**Step 3: Add tab to SettingsView.swift**

In `MeetingReminder/Views/SettingsView.swift`, add `calComService` and `calComSyncService` as `@ObservedObject` properties alongside the others:

```swift
@ObservedObject var calComService: CalComService
@ObservedObject var calComSyncService: CalComSyncService
```

In the `TabView` body (after the BusyLight tab):
```swift
CalComSettingsView(calComService: calComService, calComSyncService: calComSyncService)
    .tabItem { Label("Cal.com", systemImage: "calendar.badge.clock") }
```

**Step 4: Pass services in MeetingReminderApp.swift**

Where `SettingsView` is initialised (search for `bookingPollService:`), add:
```swift
calComService: calComService,
calComSyncService: calComSyncService,
```

**Step 5: Build**
```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project MeetingReminder.xcodeproj \
  -scheme MeetingReminder \
  -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`

**Step 6: Commit**
```bash
git add MeetingReminder/Views/CalComSettingsView.swift \
        MeetingReminder/Views/SettingsView.swift \
        MeetingReminder/MeetingReminderApp.swift \
        MeetingReminder.xcodeproj/project.pbxproj
git commit -m "feat(calcom): add CalComSettingsView + wire into Settings"
```

---

## Task 5: Deploy & smoke test

**Step 1: Full build**
```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project MeetingReminder.xcodeproj \
  -scheme MeetingReminder \
  -configuration Debug build 2>&1 | tail -5
```

**Step 2: Deploy**
```bash
killall MeetingReminder 2>/dev/null
rm -rf "/Applications/MeetingReminder.app"
cp -R "$HOME/Library/Developer/Xcode/DerivedData/MeetingReminder-altmwzoqczxbuhdhhyinjhkmcsgv/Build/Products/Debug/MeetingReminder.app" "/Applications/MeetingReminder.app"
open -a "/Applications/MeetingReminder.app"
```

**Step 3: Smoke test**
1. Open Settings → Cal.com tab should appear
2. Paste API key → Save → Test connection → should show "Connected — 7 event type(s)"
3. Event types list should populate with the 7 Cal.com types
4. Upcoming Bookings section should load
5. Enable "Sync Cal.com bookings" toggle → "Sync now" → check last sync result

**Step 4: Final commit**
```bash
git add -A
git commit -m "feat(calcom): Cal.com integration complete — service, sync, settings tab"
```
