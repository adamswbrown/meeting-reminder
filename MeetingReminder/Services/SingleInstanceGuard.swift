import AppKit
import Foundation

/// Keeps exactly one copy of the app alive.
///
/// Nothing prevented a second copy from launching alongside the first — a dev
/// build started from DerivedData or Xcode, or a deploy whose `killall` raced
/// its own `open`. A second copy is not inert: it runs a *complete* independent
/// stack — reactive calendar watcher, 06:00 Notion sync timer, intraday
/// pre-call brief trigger, busy light, availability push, booking poll — and
/// every one of those fires again for the same event. Observed live on
/// 2026-09-17: four copies each logging their own debounce to the shared
/// `calendar-notion-sync.log` (identical-millisecond quadruples, one system
/// `.EKEventStoreChanged` broadcast reaching four watchers), and each capable
/// of spawning its own headless brief for one new meeting.
///
/// **Newest wins.** We only reach this code having just launched, so every
/// other instance is by definition older and is asked to quit. Terminating
/// *them* rather than exiting *ourselves* is deliberate: a deploy that races
/// its own `killall` then still settles on exactly one running app, never zero.
/// Termination is graceful (`terminate()`, not `forceTerminate()`) so the
/// outgoing copy's `willTerminateNotification` handler still closes its panels.
enum SingleInstanceGuard {
    /// A running process, reduced to the two fields the decision needs, so the
    /// policy is testable without NSWorkspace.
    struct Instance: Equatable {
        let pid: pid_t
        let bundleID: String?
    }

    /// The instances that should be asked to quit: every process sharing our
    /// bundle identifier except ourselves. Processes with no bundle identifier,
    /// or a different one, are never touched.
    static func instancesToTerminate(running: [Instance],
                                     ownPID: pid_t,
                                     ownBundleID: String) -> [Instance] {
        running.filter { $0.pid != ownPID && $0.bundleID == ownBundleID }
    }

    /// Applies the policy against the live process list. Returns how many
    /// instances were asked to quit, for logging at the call site.
    @discardableResult
    static func terminateOtherInstances() -> Int {
        guard let ownBundleID = Bundle.main.bundleIdentifier else { return 0 }
        let own = ProcessInfo.processInfo.processIdentifier

        let running = NSWorkspace.shared.runningApplications.map {
            Instance(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier)
        }
        let doomed = Set(instancesToTerminate(running: running,
                                              ownPID: own,
                                              ownBundleID: ownBundleID).map(\.pid))
        guard !doomed.isEmpty else { return 0 }

        for app in NSWorkspace.shared.runningApplications
        where doomed.contains(app.processIdentifier) {
            app.terminate()
        }
        return doomed.count
    }
}
