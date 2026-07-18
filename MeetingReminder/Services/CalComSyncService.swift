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

    /// How long to wait before creating a local event for a new booking, giving
    /// Cal.com's Exchange integration time to sync the event down on its own.
    /// If the Exchange event arrives within this window we tag it instead.
    private static let exchangeSyncGracePeriod: TimeInterval = 20 * 60 // 20 minutes

    private let calCom: CalComService
    private let eventStore: EKEventStore
    private let notionBridge: CalComNotionBridge?
    private var timer: Timer?
    private var wakeObserver: Any?
    private var isSyncing = false

    /// Tracks the first poll cycle on which each uid was seen without a matching
    /// Exchange event. Used to implement the grace-period grace on first sighting.
    private var firstSeenUids: [String: Date] = [:]

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

        // Already tagged (idempotency — covers both app-created and Exchange-tagged events).
        if findTaggedEvent(marker: marker, near: start) != nil { return .skipped }

        // Cal.com's Office365 integration already created an Exchange calendar event.
        // If we find one at the same time with a matching title, tag it instead of
        // creating a duplicate.
        if let existing = findExchangeEvent(matching: booking.title ?? "", near: start) {
            appendMarker(marker, to: existing)
            firstSeenUids.removeValue(forKey: booking.uid) // no longer needed
            return .tagged
        }

        // Grace period: give Exchange time to sync the Cal.com-created event down
        // before we create our own copy. Track the first time we see this uid without
        // a matching Exchange event and skip creation until the grace period expires.
        let now = Date()
        if let firstSeen = firstSeenUids[booking.uid] {
            if now.timeIntervalSince(firstSeen) < Self.exchangeSyncGracePeriod {
                // Still within grace period — wait for Exchange to sync.
                return .skipped
            }
            // Grace period expired: fall through to create the event ourselves.
            firstSeenUids.removeValue(forKey: booking.uid)
        } else {
            // First time we've seen this uid with no Exchange match — start the clock.
            firstSeenUids[booking.uid] = now
            return .skipped
        }

        // No existing Exchange event after the grace period — create one so the
        // overlay / busy-light pipeline works even without Exchange connectivity.
        let attendeeLine = booking.attendees?.map { "\($0.name) <\($0.email)>" }.joined(separator: ", ") ?? ""
        // [calcom-created] marks this event as app-created (not an Exchange duplicate),
        // so cancellation can safely remove it rather than just stripping the tag.
        let createdMarker = "[calcom-created]"
        let notes = [
            "Booked via Cal.com.",
            attendeeLine.isEmpty ? nil : "Attendee: \(attendeeLine)",
            booking.location.map { "Location: \($0)" },
            marker,
            createdMarker,
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
                guard let event = findTaggedEvent(marker: marker, near: start) else { continue }

                // If the app itself created this event (marked [calcom-created]),
                // delete it entirely. If it's an Exchange-synced original that we
                // only tagged, strip the booking marker from the notes instead —
                // Exchange will remove the event on its own once Cal.com propagates
                // the cancellation server-side.
                let isAppCreated = event.notes?.contains("[calcom-created]") ?? false
                if isAppCreated {
                    try? eventStore.remove(event, span: .thisEvent, commit: true)
                } else {
                    // Strip the booking marker so the event is no longer tracked,
                    // but leave the event itself untouched (Exchange owns it).
                    var notes = event.notes ?? ""
                    notes = notes
                        .components(separatedBy: "\n")
                        .filter { !$0.contains(marker) }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    event.notes = notes.isEmpty ? nil : notes
                    try? eventStore.save(event, span: .thisEvent, commit: true)
                }
                removed += 1
            }
            return removed
        } catch {
            NSLog("[CalComSync] cancellation sync failed: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - EventKit helpers

    /// Finds an EKEvent near `date` whose title closely matches `title`.
    /// Uses a ±15 min window to absorb minor Exchange sync timing drift.
    ///
    /// Matching rules (case-insensitive, trimmed):
    ///   • Exact match, OR
    ///   • The longer title has the shorter one as a prefix AND the shorter is ≥ 4 characters.
    ///     (This handles Cal.com appending " between X and Y" to the base title without
    ///      allowing unrelated short titles to match arbitrary event titles.)
    /// Skips events that are already tagged with a Cal.com booking marker (already claimed).
    private func findExchangeEvent(matching title: String, near date: Date) -> EKEvent? {
        eventStore.refreshSourcesIfNecessary()
        let windowStart = date.addingTimeInterval(-900)
        let windowEnd   = date.addingTimeInterval(900)
        let pred = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let calTitle = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !calTitle.isEmpty else { return nil }
        return eventStore.events(matching: pred).first { event in
            // Skip events already tagged by a previous sync pass.
            if let notes = event.notes, notes.contains("[calcom-booking-id:") { return false }
            guard let ekTitle = event.title?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                  !ekTitle.isEmpty else { return false }
            // Exact match.
            if ekTitle == calTitle { return true }
            // Prefix match: the longer must start with the shorter, and the shorter must be
            // at least 4 characters to prevent "Sync" matching "Sync with the board" etc.
            let shorter = ekTitle.count < calTitle.count ? ekTitle : calTitle
            let longer  = ekTitle.count < calTitle.count ? calTitle : ekTitle
            return shorter.count >= 4 && longer.hasPrefix(shorter)
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
