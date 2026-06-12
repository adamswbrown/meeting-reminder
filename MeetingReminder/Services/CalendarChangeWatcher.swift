import EventKit
import Foundation

/// Pure decision logic for the reactive watcher's debounce + floor. Isolated
/// from NotificationCenter/Timer so the timing policy is unit-testable.
///
/// - `debounce`: settle a burst of edits into one run (default 30s).
/// - `floor`: minimum gap between two reactive runs (default 120s) so a stream
///   of edits can't hammer Notion.
struct ReactiveSyncScheduler {
    let debounce: TimeInterval
    let floor: TimeInterval

    init(debounce: TimeInterval = 30, floor: TimeInterval = 120) {
        self.debounce = debounce
        self.floor = floor
    }

    /// Absolute time a run triggered by a change at `changeAt` should fire,
    /// given the last run happened at `lastRunAt` (nil if never).
    func fireTime(changeAt: Date, lastRunAt: Date?) -> Date {
        let afterDebounce = changeAt.addingTimeInterval(debounce)
        guard let last = lastRunAt else { return afterDebounce }
        let floorBoundary = last.addingTimeInterval(floor)
        return max(afterDebounce, floorBoundary)
    }
}

/// Observes the system calendar store and triggers reactive syncs, debounced
/// and floored via `ReactiveSyncScheduler`. Coalescing: at most one pending
/// run timer exists at a time; a new change reschedules it.
@MainActor
final class CalendarChangeWatcher {
    private let store = EKEventStore()
    private let scheduler = ReactiveSyncScheduler()
    private let logger: CalendarSyncLogger
    private let onFire: () async -> Void

    private var observer: NSObjectProtocol?
    private var pendingTimer: Timer?
    private var lastRunAt: Date?

    init(logger: CalendarSyncLogger, onFire: @escaping () async -> Void) {
        self.logger = logger
        self.onFire = onFire
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleChange() }
            }
        logger.info("reactive watcher: started")
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        pendingTimer?.invalidate(); pendingTimer = nil
        logger.info("reactive watcher: stopped")
    }

    private func handleChange() {
        let fireAt = scheduler.fireTime(changeAt: Date(), lastRunAt: lastRunAt)
        let delay = max(0, fireAt.timeIntervalSinceNow)
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.fire() }
        }
        logger.debug("reactive watcher: change observed, run scheduled in \(Int(delay))s")
    }

    private func fire() async {
        pendingTimer = nil
        lastRunAt = Date()
        await onFire()
    }
}
