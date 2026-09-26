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

/// Decides what happens to a calendar change that arrives while changes are
/// being ignored — a sync in flight, or its post-run cooldown. Dropping it
/// loses a real edit until the next change or the 06:00 run; re-arming on it
/// loops forever, because a run's own `.EKEventStoreChanged` echo looks the
/// same. So an ignored change earns exactly one follow-up run, and changes
/// ignored during that follow-up (or within `echoWindow` after it) are dropped.
///
/// Residual, accepted: a genuine edit landing during a follow-up run is still
/// dropped. Cost: most runs are followed by one extra reactive run.
struct ReactiveFollowUpGate {
    /// How long after a follow-up finishes its echoes are still expected.
    /// Must cover the service's post-run cooldown.
    let echoWindow: TimeInterval

    /// Whether the next fire is a follow-up (vs a run for a genuine change).
    private(set) var nextFireIsFollowUp = false
    private var followUpInFlight = false
    private var followUpFinishedAt: Date?

    init(echoWindow: TimeInterval = 60) {
        self.echoWindow = echoWindow
    }

    /// A change arrived while ignoring. Returns whether to schedule a follow-up.
    mutating func ignoredChange(at now: Date) -> Bool {
        if followUpInFlight { return false }
        if let t = followUpFinishedAt, now.timeIntervalSince(t) < echoWindow { return false }
        nextFireIsFollowUp = true
        return true
    }

    mutating func fireStarting() {
        followUpInFlight = nextFireIsFollowUp
        nextFireIsFollowUp = false
    }

    /// `ran == false` means the run was skipped (busy); a skipped follow-up
    /// stays a follow-up when it's rescheduled.
    mutating func fireFinished(ran: Bool, at now: Date) {
        if ran {
            if followUpInFlight { followUpFinishedAt = now }
        } else if followUpInFlight {
            nextFireIsFollowUp = true
        }
        followUpInFlight = false
    }
}

/// Observes the system calendar store and triggers reactive syncs, debounced
/// and floored via `ReactiveSyncScheduler`. Coalescing: at most one pending
/// run timer exists at a time; a new change reschedules it.
@MainActor
final class CalendarChangeWatcher {
    private let scheduler = ReactiveSyncScheduler()
    private var followUpGate = ReactiveFollowUpGate()
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
        // a short cooldown after. A real edit can land in that window too, so
        // an ignored change still earns one follow-up run (see
        // `ReactiveFollowUpGate`).
        if shouldIgnoreChange() {
            if followUpGate.ignoredChange(at: Date()) {
                logger.debug("reactive watcher: change during sync / cooldown — follow-up run queued")
                scheduleFire()
            } else {
                logger.debug("reactive watcher: change ignored (echo of follow-up run)")
            }
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
        followUpGate.fireStarting()
        let ran = await onFire()
        followUpGate.fireFinished(ran: ran, at: Date())
        if ran {
            // Only mark the floor once the run actually executed. Setting it
            // before the await (the old behaviour) meant a change that hit the
            // service's `isRunning` guard was counted as done and never
            // re-synced. Floor is start-to-start, so measuring from completion
            // is a slight over-approximation — acceptable, and safer than
            // dropping edits.
            lastRunAt = Date()
            // A follow-up armed while this run was in flight used the old
            // `lastRunAt`; re-arm it so the floor is measured from this run.
            if followUpGate.nextFireIsFollowUp { scheduleFire() }
        } else {
            // The run was skipped (another sync in flight). Re-schedule the
            // debounced fire so this change is eventually reconciled rather
            // than silently lost.
            logger.debug("reactive watcher: run skipped (busy), rescheduling")
            scheduleFire()
        }
    }
}
