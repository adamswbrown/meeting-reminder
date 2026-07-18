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
    private let scheduler = ReactiveSyncScheduler()
    private let logger: CalendarSyncLogger
    /// Fires a reactive sync. Returns whether the run actually executed —
    /// `false` means it was skipped (another run in flight), so the watcher
    /// re-schedules the debounce instead of counting the change as handled.
    private let onFire: () async -> Bool
    /// Queried on each incoming notification. When it returns `true` the
    /// notification is a self-inflicted echo (a sync run is in progress or just
    /// finished — `store.refreshSourcesIfNecessary()` can post `.EKEventStoreChanged`),
    /// so we ignore it to avoid a ~2.5-min self-perpetuating loop.
    private let shouldIgnoreChange: () -> Bool

    private var observer: NSObjectProtocol?
    private var pendingTimer: Timer?
    private var lastRunAt: Date?

    init(logger: CalendarSyncLogger,
         shouldIgnoreChange: @escaping () -> Bool = { false },
         onFire: @escaping () async -> Bool) {
        self.logger = logger
        self.shouldIgnoreChange = shouldIgnoreChange
        self.onFire = onFire
    }

    deinit {
        // The block-based observer is retained by NotificationCenter and the
        // scheduled Timer by the run loop, independent of `self`'s lifetime —
        // so clean both up even if `stop()` was never called.
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        pendingTimer?.invalidate()
    }

    func start() {
        guard observer == nil else { return }
        // Observe with `object: nil` — EventKit does not always post this
        // notification with a store instance as the sender, so filtering by
        // object can silently drop sync-driven updates. This matches the
        // hard-won precedent in CalendarService.setupNotificationObserver().
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
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
        // Ignore self-inflicted echoes: a sync run's `refreshSourcesIfNecessary()`
        // can post `.EKEventStoreChanged`, which would otherwise re-trigger us in
        // a ~2.5-min loop. The service suppresses for the duration of a run plus
        // a short cooldown after.
        if shouldIgnoreChange() {
            logger.debug("reactive watcher: change ignored (sync in progress / cooldown)")
            return
        }
        scheduleFire()
    }

    /// Arms (or re-arms) the single debounced fire timer. Bypasses the
    /// ignore-echo check on purpose — used both by `handleChange()` (after the
    /// check passes) and by `fire()`'s skipped-busy reschedule, where we must
    /// re-queue even though `shouldIgnoreChange()` is momentarily true because a
    /// run is still in flight.
    private func scheduleFire() {
        let fireAt = scheduler.fireTime(changeAt: Date(), lastRunAt: lastRunAt)
        let delay = max(0, fireAt.timeIntervalSinceNow)
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.fire() }
        }
        logger.debug("reactive watcher: run scheduled in \(Int(delay))s")
    }

    private func fire() async {
        pendingTimer = nil
        let ran = await onFire()
        if ran {
            // Only mark the floor once the run actually executed. Setting it
            // before the await (the old behaviour) meant a change that hit the
            // service's `isRunning` guard was counted as done and never
            // re-synced. Floor is start-to-start, so measuring from completion
            // is a slight over-approximation — acceptable, and safer than
            // dropping edits.
            lastRunAt = Date()
        } else {
            // The run was skipped (another sync in flight). Re-schedule the
            // debounced fire so this change is eventually reconciled rather
            // than silently lost.
            logger.debug("reactive watcher: run skipped (busy), rescheduling")
            scheduleFire()
        }
    }
}
