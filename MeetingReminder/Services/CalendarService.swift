import AppKit
import Combine
import EventKit
import Foundation

@MainActor
final class CalendarService: ObservableObject {
    @Published var events: [MeetingEvent] = []
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var availableCalendars: [EKCalendar] = []

    private let eventStore = EKEventStore()
    private var refreshTimer: Timer?
    private var storeChangeObserver: Any?
    private var wakeObserver: Any?

    init() {
        updateAuthorizationStatus()
        setupNotificationObserver()
    }

    deinit {
        refreshTimer?.invalidate()
        if let observer = storeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func requestAccess() async {
        if #available(macOS 14.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                updateAuthorizationStatus()
                if granted {
                    fetchEvents()
                    startAutoRefresh()
                }
            } catch {
                print("Calendar access error: \(error)")
            }
        } else {
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            updateAuthorizationStatus()
            if granted {
                fetchEvents()
                startAutoRefresh()
            }
        }
    }

    func startMonitoring() {
        fetchEvents()
        startAutoRefresh()
    }

    func fetchEvents() {
        // Ask EventKit to pull any pending remote changes before we query the
        // store. For Google / Exchange / iCloud calendars, a deletion on the
        // server won't be visible to `events(matching:)` until the local store
        // syncs — and that doesn't happen on its own just because we asked.
        // Without this, a cancelled meeting can linger in the menu bar for
        // minutes until the next autonomous sync.
        eventStore.refreshSourcesIfNecessary()

        let now = Date()
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now)!

        // Reach back 2 hours so the user can join meetings they're running late to —
        // an in-progress or recently-started meeting must stay visible in the menu
        // bar list even if it kicked off well before the app was opened.
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-7200),
            end: endOfDay,
            calendars: nil
        )

        let ekEvents = eventStore.events(matching: predicate)

        let enabledCalendarIDs = Set(
            UserDefaults.standard.stringArray(forKey: "enabledCalendarIDs") ?? []
        )

        events = ekEvents
            .filter { event in
                // Filter out all-day events
                guard !event.isAllDay else { return false }

                // Filter out declined events
                if let attendees = event.attendees,
                   let me = attendees.first(where: { $0.isCurrentUser }),
                   me.participantStatus == .declined {
                    return false
                }

                // Filter by enabled calendars (if any are configured)
                if !enabledCalendarIDs.isEmpty {
                    return enabledCalendarIDs.contains(event.calendar.calendarIdentifier)
                }

                return true
            }
            .map { ekEvent in
                let videoLink = VideoLinkDetector.detectLink(in: ekEvent)
                return MeetingEvent(from: ekEvent, videoLink: videoLink)
            }
            .sorted { $0.startDate < $1.startDate }

        availableCalendars = eventStore.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Meeting Statistics

    /// Total number of meetings today
    var totalMeetingCount: Int {
        events.count
    }

    /// Total meeting hours today
    var totalMeetingHours: Double {
        let totalMinutes = events.reduce(0) { $0 + $1.durationMinutes }
        return Double(totalMinutes) / 60.0
    }

    /// Number of back-to-back meeting blocks (< 5 min gap)
    var backToBackCount: Int {
        guard events.count > 1 else { return 0 }
        var count = 0
        for i in 0..<(events.count - 1) {
            let gap = events[i + 1].startDate.timeIntervalSince(events[i].endDate)
            if gap < 300 { // < 5 minutes
                count += 1
            }
        }
        return count
    }

    /// Next break (gap > 15 min between meetings)
    var nextBreakTime: Date? {
        let now = Date()
        for i in 0..<events.count {
            let event = events[i]
            // Skip events that have already ended
            guard event.endDate > now else { continue }

            if i + 1 < events.count {
                let gap = events[i + 1].startDate.timeIntervalSince(event.endDate)
                if gap >= 900 { // >= 15 min gap
                    return event.endDate
                }
            } else {
                // Last meeting of the day — break starts when it ends
                return event.endDate
            }
        }
        return nil
    }

    var formattedNextBreak: String? {
        guard let breakTime = nextBreakTime else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: breakTime)
    }

    /// Check if the next meeting after the given event is back-to-back (< 5 min gap)
    func nextBackToBackEvent(after event: MeetingEvent) -> MeetingEvent? {
        guard let index = events.firstIndex(where: { $0.id == event.id }),
              index + 1 < events.count else { return nil }
        let next = events[index + 1]
        let gap = next.startDate.timeIntervalSince(event.endDate)
        return gap < 300 ? next : nil
    }

    // MARK: - Private

    private func updateAuthorizationStatus() {
        if #available(macOS 14.0, *) {
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        } else {
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        }
    }

    private func startAutoRefresh() {
        // Poll every 60s so a newly-added calendar event (especially from a
        // remote source like Google/Exchange that hasn't pushed a change
        // notification yet) shows up within about a minute. `fetchEvents`
        // also calls `refreshSourcesIfNecessary`, which hints EventKit to
        // pull remote updates — the poll is what kicks that off.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchEvents()
            }
        }
    }

    private func setupNotificationObserver() {
        // Observe with `object: nil` — EventKit does not always post this
        // notification with the store instance as the sender, so filtering by
        // object can silently drop sync-driven updates.
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fetchEvents()
            }
        }

        // Laptops that wake from sleep can be minutes behind — fetch immediately
        // on wake so the menu bar isn't showing a stale list.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fetchEvents()
            }
        }
    }
}
