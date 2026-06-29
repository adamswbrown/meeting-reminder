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
    private var timer: Timer?
    private var wakeObserver: Any?
    private var isSyncing = false

    init(calCom: CalComService, eventStore: EKEventStore = EKEventStore()) {
        self.calCom = calCom
        self.eventStore = eventStore
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

        do {
            let bookings = try await calCom.fetchUpcomingBookings(after: after)
            var synced = 0
            var skipped = 0

            for booking in bookings {
                let created = await createEKEventIfNeeded(for: booking)
                if created { synced += 1 } else { skipped += 1 }
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

    // MARK: - EKEvent creation

    /// Returns true if a new EKEvent was created, false if already present.
    private func createEKEventIfNeeded(for booking: CalComBooking) async -> Bool {
        guard let start = booking.startDate, let end = booking.endDate else { return false }
        let marker = "[calcom-booking-id:\(booking.uid)]"

        if findTaggedEvent(marker: marker, near: start) != nil { return false }

        let attendeeLine = booking.attendees?.map { "\($0.name) <\($0.email)>" }.joined(separator: ", ") ?? ""
        let notes = [
            "Booked via Cal.com.",
            attendeeLine.isEmpty ? nil : "Attendee: \(attendeeLine)",
            booking.location.map { "Location: \($0)" },
            marker
        ].compactMap { $0 }.joined(separator: "\n")

        guard let calendar = eventStore.defaultCalendarForNewEvents else { return false }

        let event = EKEvent(eventStore: eventStore)
        event.title = booking.title ?? "Meeting"
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = calendar

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return true
        } catch {
            NSLog("[CalComSync] save failed for \(booking.uid): \(error.localizedDescription)")
            return false
        }
    }

    private func findTaggedEvent(marker: String, near date: Date) -> EKEvent? {
        eventStore.refreshSourcesIfNecessary()
        let start = date.addingTimeInterval(-300)
        let end = date.addingTimeInterval(300)
        let pred = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: pred).first { $0.notes?.contains(marker) == true }
    }
}
