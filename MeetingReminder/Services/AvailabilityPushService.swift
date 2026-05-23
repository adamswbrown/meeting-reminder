import Combine
import EventKit
import Foundation

/// Pushes a free/busy snapshot of the user's calendar to Supabase so that a
/// public web frontend (e.g. a Vercel-hosted availability page) can read it
/// without needing direct calendar API access.
///
/// Design notes:
///
/// - **Source**: queries `EKEventStore` directly rather than going through
///   `CalendarService`, because `CalendarService` filters out all-day events
///   (`CalendarService.swift:93`). For availability we want all-day OOO blocks
///   to count as busy.
/// - **Auth**: uses the Supabase service-role key stored in Keychain. This is
///   appropriate for a single-user personal tool — the key never leaves the
///   Mac. The Vercel frontend reads via the anon key against a sanitised
///   public view that strips titles and attendees.
/// - **Window**: 14 days forward from "now". Anything outside that window is
///   considered stale and either deleted on next sync or just never written.
/// - **Cancellations**: every push computes the set of event_ids in the
///   current EventKit snapshot, then DELETEs any rows in Supabase within the
///   same window whose event_id isn't in the snapshot. That's how rescheduled
///   or cancelled events disappear from the public page.
/// - **Drift**: configurable, default 5 min. The Mac being asleep stops sync;
///   the `sync_state` table's `last_synced_at` lets the frontend render a
///   "data is N min old" pill.
@MainActor
final class AvailabilityPushService: ObservableObject {
    // MARK: - Published state

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }
    @Published var lastSyncDate: Date?
    @Published var lastError: String?
    @Published var lastSyncCount: Int = 0
    @Published var isSyncing: Bool = false

    // MARK: - Persistence keys

    private static let enabledKey = "availabilityPushEnabled"
    private static let projectURLKey = "supabaseProjectURL"
    private static let serviceKeyKeychainKey = "supabaseServiceRoleKey"
    private static let intervalKey = "availabilityPushIntervalMinutes"
    private static let windowKey = "availabilityPushWindowDays"

    /// Default to 5 min — comfortably under the user's 30 min drift budget,
    /// well above Supabase's free-tier rate limits.
    static let defaultIntervalMinutes: Int = 5

    /// 14 days forward. Anything further out isn't useful for "when am I free"
    /// and Outlook recurring expansions get noisy past a fortnight.
    static let defaultWindowDays: Int = 14

    // MARK: - Configuration

    var projectURL: String {
        get { UserDefaults.standard.string(forKey: Self.projectURLKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.projectURLKey)
            objectWillChange.send()
        }
    }

    var serviceRoleKey: String? {
        KeychainHelper.read(key: Self.serviceKeyKeychainKey)
    }

    var intervalMinutes: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.intervalKey)
            return stored == 0 ? Self.defaultIntervalMinutes : stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.intervalKey)
            objectWillChange.send()
            if isEnabled { start() }
        }
    }

    var windowDays: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.windowKey)
            return stored == 0 ? Self.defaultWindowDays : stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.windowKey)
            objectWillChange.send()
        }
    }

    var isConfigured: Bool {
        guard let key = serviceRoleKey else { return false }
        return !key.isEmpty && !projectURL.isEmpty
    }

    // MARK: - Internals

    private let eventStore: EKEventStore
    private var timer: Timer?

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Credential management

    func setServiceRoleKey(_ key: String) {
        KeychainHelper.save(key: Self.serviceKeyKeychainKey, value: key)
        objectWillChange.send()
    }

    func clearCredentials() {
        KeychainHelper.delete(key: Self.serviceKeyKeychainKey)
        projectURL = ""
        objectWillChange.send()
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        guard isEnabled, isConfigured else { return }

        // Fire one immediately on start so the user gets feedback that it's working.
        Task { await pushNow() }

        let interval = TimeInterval(intervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pushNow()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Push

    /// Snapshot the next N days of events from EventKit and upsert them to
    /// Supabase. Anything currently in Supabase in the same window that's no
    /// longer in EventKit is deleted (handles cancellations and reschedules).
    func pushNow() async {
        guard isConfigured else {
            lastError = "Not configured — set project URL + service-role key in Settings."
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let snapshot = collectSnapshot(daysForward: windowDays)

        do {
            try await upsertEvents(snapshot.events)
            try await deleteMissing(
                eventIDs: snapshot.eventIDs,
                windowStart: snapshot.windowStart,
                windowEnd: snapshot.windowEnd
            )
            try await updateSyncState(
                count: snapshot.events.count,
                windowEnd: snapshot.windowEnd
            )
            lastSyncDate = Date()
            lastSyncCount = snapshot.events.count
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - EventKit snapshot

    private struct Snapshot {
        let events: [PushEvent]
        let eventIDs: Set<String>
        let windowStart: Date
        let windowEnd: Date
    }

    private func collectSnapshot(daysForward: Int) -> Snapshot {
        // Force a remote-store refresh so cancellations from Outlook/Google
        // make it into the snapshot. Same pattern as CalendarService.swift:70.
        eventStore.refreshSourcesIfNecessary()

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: daysForward, to: now) ?? now

        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: end,
            calendars: nil
        )

        let enabledCalendarIDs = Set(
            UserDefaults.standard.stringArray(forKey: "enabledCalendarIDs") ?? []
        )

        let pushed = eventStore.events(matching: predicate)
            .filter { event in
                // Filter out declined-by-me. We still keep tentative and
                // accepted both — tentative defaults to is_tentative=true so
                // the frontend can decide whether to show them as busy.
                if let attendees = event.attendees,
                   let me = attendees.first(where: { $0.isCurrentUser }),
                   me.participantStatus == .declined {
                    return false
                }
                // Honour the user's selected-calendars filter if set.
                if !enabledCalendarIDs.isEmpty {
                    return enabledCalendarIDs.contains(event.calendar.calendarIdentifier)
                }
                return true
            }
            .map { PushEvent(from: $0) }

        return Snapshot(
            events: pushed,
            eventIDs: Set(pushed.map { $0.eventID }),
            windowStart: now,
            windowEnd: end
        )
    }

    // MARK: - Supabase REST

    private func upsertEvents(_ events: [PushEvent]) async throws {
        guard !events.isEmpty else { return }
        let payload = events.map { $0.toJSONDictionary() }
        let url = try restURL(path: "/rest/v1/calendar_events", query: "on_conflict=event_id")
        var request = try authedRequest(url: url, method: "POST")
        request.addValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await send(request)
    }

    private func deleteMissing(eventIDs: Set<String>, windowStart: Date, windowEnd: Date) async throws {
        // PostgREST filter syntax: not.in.(id1,id2,...). If the keep-set is
        // empty we still want to clear the window; PostgREST rejects an empty
        // `in.()` list, so skip the not-in clause in that case.
        let iso = ISO8601DateFormatter()
        let startISO = iso.string(from: windowStart)
        let endISO = iso.string(from: windowEnd)

        var queryParts = [
            "start_utc=gte.\(startISO)",
            "start_utc=lt.\(endISO)",
        ]
        if !eventIDs.isEmpty {
            // PostgREST requires comma-separated, quoted strings inside `in.(...)`.
            // Quote each id and escape internal quotes by doubling them.
            let quoted = eventIDs.map { id -> String in
                let escaped = id.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }.joined(separator: ",")
            queryParts.append("event_id=not.in.(\(quoted))")
        }
        let query = queryParts.joined(separator: "&")

        let url = try restURL(path: "/rest/v1/calendar_events", query: query)
        let request = try authedRequest(url: url, method: "DELETE")
        try await send(request)
    }

    private func updateSyncState(count: Int, windowEnd: Date) async throws {
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "last_synced_at": iso.string(from: Date()),
            "next_sync_window_end": iso.string(from: windowEnd),
            "events_in_window": count,
        ]
        let url = try restURL(path: "/rest/v1/sync_state", query: "id=eq.1")
        var request = try authedRequest(url: url, method: "PATCH")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await send(request)
    }

    // MARK: - Request helpers

    private func restURL(path: String, query: String) throws -> URL {
        let base = projectURL.hasSuffix("/")
            ? String(projectURL.dropLast())
            : projectURL
        guard let url = URL(string: "\(base)\(path)?\(query)") else {
            throw AvailabilityPushError.invalidURL(base + path)
        }
        return url
    }

    private func authedRequest(url: URL, method: String) throws -> URLRequest {
        guard let key = serviceRoleKey, !key.isEmpty else {
            throw AvailabilityPushError.missingCredentials
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue(key, forHTTPHeaderField: "apikey")
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AvailabilityPushError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AvailabilityPushError.httpError(http.statusCode, body)
        }
    }
}

// MARK: - Push event payload

/// A flattened event ready to send to Supabase. Kept separate from
/// `MeetingEvent` because the availability snapshot includes all-day events
/// (which `MeetingEvent` doesn't carry through `CalendarService`).
struct PushEvent {
    let eventID: String
    let title: String
    let startUTC: Date
    let endUTC: Date
    let isAllDay: Bool
    let isTentative: Bool
    let isOOO: Bool
    let status: String
    let calendarName: String
    let hasVideoLink: Bool

    init(from ekEvent: EKEvent) {
        // Stable per-occurrence ID, same convention as MeetingEvent.swift:101-103
        // so the two paths agree on identity.
        let base = ekEvent.eventIdentifier ?? UUID().uuidString
        let stamp = ISO8601DateFormatter().string(from: ekEvent.startDate)
        self.eventID = "\(base)_\(stamp)"
        self.title = ekEvent.title ?? "Untitled"
        self.startUTC = ekEvent.startDate
        self.endUTC = ekEvent.endDate
        self.isAllDay = ekEvent.isAllDay
        self.calendarName = ekEvent.calendar.title

        let myStatus = ekEvent.attendees?.first(where: { $0.isCurrentUser })?.participantStatus
        self.isTentative = (myStatus == .tentative)

        // Reuse the same OOO detection the Notion sync uses: EKEventAvailability
        // when Exchange provides it, falling back to a title heuristic for the
        // common case where the Exchange bridge drops the OOO bit on all-day
        // leave blocks. `availabilityName` returns "OOO" in both cases.
        self.isOOO = (CalendarEventMapper.availabilityName(for: ekEvent) == "OOO")

        switch ekEvent.status {
        case .canceled:
            self.status = "cancelled"
        default:
            self.status = (myStatus == .tentative) ? "tentative" : "confirmed"
        }

        self.hasVideoLink = VideoLinkDetector.detectLink(in: ekEvent) != nil
    }

    func toJSONDictionary() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "event_id": eventID,
            "title": String(title.prefix(500)),
            "start_utc": iso.string(from: startUTC),
            "end_utc": iso.string(from: endUTC),
            "is_all_day": isAllDay,
            "is_tentative": isTentative,
            "is_ooo": isOOO,
            "status": status,
            "calendar_name": String(calendarName.prefix(200)),
            "has_video_link": hasVideoLink,
            "source": "macos-eventkit",
        ]
    }
}

// MARK: - Errors

enum AvailabilityPushError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case missingCredentials
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s):     return "Invalid Supabase URL: \(s)"
        case .invalidResponse:       return "Invalid response from Supabase"
        case .missingCredentials:    return "Missing service-role key"
        case .httpError(let c, let body):
            return "HTTP \(c)\(body.isEmpty ? "" : " — \(body)")"
        }
    }
}
