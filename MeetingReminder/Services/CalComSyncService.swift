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
    /// Notes marker for events this service created itself (vs. tagged Exchange copies).
    private static let createdMarker = "[calcom-created]"

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
        if let tagged = findTaggedEvent(marker: marker, near: start) {
            // Reconciliation: we created our own copy after the grace period, but
            // the Exchange copy has since arrived (late sync). Move the tag onto
            // the Exchange event and delete ours so the meeting isn't doubled.
            if tagged.notes?.contains(Self.createdMarker) == true,
               let exchange = findExchangeEvent(matching: booking, near: start, strict: true) {
                appendMarker(marker, to: exchange)
                do {
                    try eventStore.remove(tagged, span: .thisEvent, commit: true)
                    NSLog("[CalComSync] \(booking.uid): Exchange copy arrived — removed app-created duplicate")
                } catch {
                    NSLog("[CalComSync] \(booking.uid): duplicate removal failed: \(error.localizedDescription)")
                }
                return .tagged
            }
            return .skipped
        }

        // Cal.com's Office365 integration already created an Exchange calendar event.
        // If we find one at the same time with a matching title (or the booker invited),
        // tag it instead of creating a duplicate.
        if let existing = findExchangeEvent(matching: booking, near: start) {
            appendMarker(marker, to: existing)
            firstSeenUids.removeValue(forKey: booking.uid) // no longer needed
            // Most bookings take this path (Exchange syncs within the grace
            // period), so the notes page must be created here as well as on
            // .created — otherwise tagged meetings never get one.
            if let bridge = notionBridge {
                Task { await bridge.createPageIfNeeded(for: booking) }
            }
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
        let notes = [
            "Booked via Cal.com.",
            attendeeLine.isEmpty ? nil : "Attendee: \(attendeeLine)",
            booking.location.map { "Location: \($0)" },
            marker,
            Self.createdMarker,
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
                let isAppCreated = event.notes?.contains(Self.createdMarker) ?? false
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

    /// Finds an EKEvent near the booking's start that looks like the Exchange copy
    /// Cal.com created. Uses a ±15 min window to absorb minor Exchange sync timing drift.
    /// Skips events that are already tagged with a Cal.com booking marker (already claimed).
    /// `strict` is for the reconciliation path, which *deletes* the app-created copy
    /// on a match — it requires the title to match as well as the booker.
    private func findExchangeEvent(matching booking: CalComBooking, near date: Date,
                                   strict: Bool = false) -> EKEvent? {
        eventStore.refreshSourcesIfNecessary()
        let windowStart = date.addingTimeInterval(-900)
        let windowEnd   = date.addingTimeInterval(900)
        let pred = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        // Cal.com lists the booker first; guests added later (e.g. the cal-auto
        // function adding colleagues to every booking) come after, and must not
        // be used to match — they share plenty of unrelated internal meetings.
        let bookerEmail = booking.attendees?.first?.email
        return eventStore.events(matching: pred).first { event in
            // Skip events already tagged by a previous sync pass.
            if let notes = event.notes, notes.contains("[calcom-booking-id:") { return false }
            let emails = (event.attendees ?? []).compactMap(Self.mailtoAddress)
            return Self.isLikelyExchangeCopy(
                ekTitle: event.title, ekAttendeeEmails: emails,
                ekOrganizerIsCurrentUser: event.organizer?.isCurrentUser ?? false,
                ekOrganizerEmail: event.organizer.flatMap(Self.mailtoAddress),
                startOffset: event.startDate.timeIntervalSince(date),
                calTitle: booking.title ?? "", bookerEmail: bookerEmail, strict: strict)
        }
    }

    private nonisolated static func mailtoAddress(_ p: EKParticipant) -> String? {
        guard p.url.scheme == "mailto" else { return nil }
        return p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
    }

    /// Matching rules for an Exchange event already in the booking's time window
    /// (titles case-insensitive, trimmed).
    ///
    /// Title match — either:
    ///   • Exact title match, OR
    ///   • The longer title has the shorter one as a prefix AND the shorter is ≥ 4 characters.
    ///     (This handles Cal.com appending " between X and Y" to the base title without
    ///      allowing unrelated short titles to match arbitrary event titles.)
    ///
    /// Booker match (covers an Exchange copy whose title was renamed) — all of:
    ///   • The event invites the booker (the booking's *first* attendee; guests are
    ///     ignored because they are colleagues who share unrelated meetings),
    ///   • the booker is not on the organiser's own domain (a colleague booking would
    ///     otherwise match every internal meeting with them),
    ///   • the current user organises the event (Cal.com's Exchange copy is created
    ///     on the host's calendar, so a meeting someone else sent is never it), and
    ///   • it starts within 15 min of the booking.
    ///
    /// Non-strict (first-tag path): title match OR booker match.
    /// Strict (reconciliation, which deletes the app's copy): the title must match,
    /// and the booker must be invited whenever both sides carry attendees.
    nonisolated static func isLikelyExchangeCopy(ekTitle: String?, ekAttendeeEmails: [String],
                                                 ekOrganizerIsCurrentUser: Bool,
                                                 ekOrganizerEmail: String?,
                                                 startOffset: TimeInterval,
                                                 calTitle: String, bookerEmail: String?,
                                                 strict: Bool = false) -> Bool {
        let booker = bookerEmail?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let invited = Set(ekAttendeeEmails.map { $0.lowercased() })
        let bookerInvited = !booker.isEmpty && invited.contains(booker)
        let titleMatch = titlesMatch(ekTitle, calTitle)

        if strict {
            guard titleMatch else { return false }
            if booker.isEmpty || invited.isEmpty { return true }
            return bookerInvited
        }
        if titleMatch { return true }

        guard bookerInvited, ekOrganizerIsCurrentUser, abs(startOffset) <= 900 else { return false }
        if let organizer = ekOrganizerEmail?.lowercased(),
           let orgDomain = organizer.split(separator: "@").last,
           let bookerDomain = booker.split(separator: "@").last,
           organizer.contains("@"), orgDomain == bookerDomain {
            return false
        }
        return true
    }

    private nonisolated static func titlesMatch(_ ekTitle: String?, _ calTitle: String) -> Bool {
        let calTitle = calTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !calTitle.isEmpty,
              let ekTitle = ekTitle?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !ekTitle.isEmpty else { return false }
        // Exact match.
        if ekTitle == calTitle { return true }
        // Prefix match: the longer must start with the shorter, and the shorter must be
        // at least 4 characters to prevent "Sync" matching "Sync with the board" etc.
        let shorter = ekTitle.count < calTitle.count ? ekTitle : calTitle
        let longer  = ekTitle.count < calTitle.count ? calTitle : ekTitle
        return shorter.count >= 4 && longer.hasPrefix(shorter)
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
