import AppKit
import EventKit
import Foundation

/// Syncs Cal.com upcoming bookings into local EKEvents.
/// Polls every 5 min while awake + once on NSWorkspace.didWakeNotification.
/// Tags each event `[calcom-booking-id:<uid>]` for idempotency.
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
    private let notionBridge: CalComNotionBridge?
    private var timer: Timer?
    private var wakeObserver: Any?
    private var isSyncing = false

    init(calCom: CalComService, eventStore: EKEventStore = EKEventStore(), notionBridge: CalComNotionBridge? = nil) {
        self.calCom = calCom
        self.eventStore = eventStore
        self.notionBridge = notionBridge
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.lastSyncedAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
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

        // Look back 1h to catch bookings made while Mac was asleep.
        let lookback = Date().addingTimeInterval(-3600)
        let after = (lastSyncedAt.map { min($0, lookback) }) ?? lookback
        // Look back 30 days for cancellations of previously-upcoming meetings.
        let cancelLookback = Date().addingTimeInterval(-30 * 24 * 3600)

        do {
            let bookings = try await calCom.fetchUpcomingBookings(after: after)
            var created = 0
            var tagged = 0
            var skipped = 0

            for booking in bookings {
                switch await syncBooking(booking) {
                case .created: created += 1
                case .tagged:  tagged += 1
                case .skipped: skipped += 1
                }
            }

            let cancelled = await syncCancellations(after: cancelLookback)

            lastSyncedAt = Date()
            UserDefaults.standard.set(lastSyncedAt, forKey: Self.lastSyncKey)
            var parts = ["created=\(created)"]
            if tagged > 0   { parts.append("tagged=\(tagged)") }
            if skipped > 0  { parts.append("skipped=\(skipped)") }
            if cancelled > 0 { parts.append("cancelled=\(cancelled)") }
            lastSyncResult = parts.joined(separator: " ")
            lastError = nil

        } catch {
            lastError = error.localizedDescription
            lastSyncedAt = Date()
        }
    }

    private enum BookingSyncResult { case created, tagged, skipped }

    // MARK: - Upcoming bookings

    private func syncBooking(_ booking: CalComBooking) async -> BookingSyncResult {
        guard let start = booking.startDate, let end = booking.endDate else { return .skipped }
        let marker = "[calcom-booking-id:\(booking.uid)]"

        // Already tagged (idempotency).
        if findTaggedEvent(marker: marker, near: start) != nil { return .skipped }

        // Cal.com's Office365 integration already created an Exchange calendar event.
        // If we find one at the same time with a matching title, tag it instead of
        // creating a duplicate.
        if let existing = findExchangeEvent(matching: booking.title ?? "", near: start) {
            appendMarker(marker, to: existing)
            return .tagged
        }

        // No existing event — create one (e.g. for calendars not connected to Exchange).
        let attendeeLine = booking.attendees?.map { "\($0.name) <\($0.email)>" }.joined(separator: ", ") ?? ""
        let notes = [
            "Booked via Cal.com.",
            attendeeLine.isEmpty ? nil : "Attendee: \(attendeeLine)",
            booking.location.map { "Location: \($0)" },
            marker
        ].compactMap { $0 }.joined(separator: "\n")

        guard let calendar = eventStore.defaultCalendarForNewEvents else { return .skipped }

        let event = EKEvent(eventStore: eventStore)
        event.title = booking.title ?? "Meeting"
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = calendar

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            NSLog("[CalComSync] save failed for \(booking.uid): \(error.localizedDescription)")
            return .skipped
        }

        // Side-effect: create a Notion meeting-notes page for new bookings so
        // the pre-call brief pipeline has something to link to before the next
        // CalendarNotionSyncService run.
        if let bridge = notionBridge {
            Task { await bridge.createPageIfNeeded(for: booking) }
        }
        return .created
    }

    // MARK: - Cancellations

    private func syncCancellations(after: Date) async -> Int {
        do {
            let cancelled = try await calCom.fetchCancelledBookings(after: after)
            var removed = 0
            for booking in cancelled {
                guard let start = booking.startDate else { continue }
                let marker = "[calcom-booking-id:\(booking.uid)]"
                if let event = findTaggedEvent(marker: marker, near: start) {
                    try? eventStore.remove(event, span: .thisEvent, commit: true)
                    removed += 1
                }
            }
            return removed
        } catch {
            NSLog("[CalComSync] cancellation sync failed: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - EventKit helpers

    /// Finds an EKEvent near `date` whose title overlaps with `title` (case-insensitive substring match).
    /// Uses a ±15 min window to absorb minor Exchange sync timing drift.
    private func findExchangeEvent(matching title: String, near date: Date) -> EKEvent? {
        eventStore.refreshSourcesIfNecessary()
        let windowStart = date.addingTimeInterval(-900)
        let windowEnd   = date.addingTimeInterval(900)
        let pred = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let calTitle = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return eventStore.events(matching: pred).first { event in
            guard let ekTitle = event.title?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            // Match if either title contains the other — handles Cal.com appending " between X and Y"
            return ekTitle.contains(calTitle) || calTitle.contains(ekTitle)
        }
    }

    private func findTaggedEvent(marker: String, near date: Date) -> EKEvent? {
        eventStore.refreshSourcesIfNecessary()
        let pred = eventStore.predicateForEvents(
            withStart: date.addingTimeInterval(-900),
            end: date.addingTimeInterval(900),
            calendars: nil
        )
        return eventStore.events(matching: pred).first { $0.notes?.contains(marker) == true }
    }

    private func appendMarker(_ marker: String, to event: EKEvent) {
        var notes = event.notes ?? ""
        guard !notes.contains(marker) else { return }
        if !notes.isEmpty { notes += "\n" }
        notes += marker
        event.notes = notes
        try? eventStore.save(event, span: .thisEvent, commit: true)
    }
}
