import XCTest
@testable import MeetingReminder

final class SingleInstanceGuardTests: XCTestCase {
    private let ownBundle = "com.meetingreminder.app"

    private func inst(_ pid: pid_t, _ bundle: String?) -> SingleInstanceGuard.Instance {
        SingleInstanceGuard.Instance(pid: pid, bundleID: bundle)
    }

    func testNoOtherInstancesTerminatesNothing() {
        let running = [inst(100, ownBundle)]
        XCTAssertTrue(SingleInstanceGuard.instancesToTerminate(
            running: running, ownPID: 100, ownBundleID: ownBundle).isEmpty)
    }

    func testOlderSiblingIsTerminated() {
        let running = [inst(100, ownBundle), inst(200, ownBundle)]
        let doomed = SingleInstanceGuard.instancesToTerminate(
            running: running, ownPID: 200, ownBundleID: ownBundle)
        XCTAssertEqual(doomed, [inst(100, ownBundle)])
    }

    /// The deploy-churn case that produced four concurrent watchers: several
    /// stale copies must all be cleaned up, not just the most recent one.
    func testAllOlderSiblingsAreTerminated() {
        let running = [inst(100, ownBundle), inst(101, ownBundle),
                       inst(102, ownBundle), inst(200, ownBundle)]
        let doomed = SingleInstanceGuard.instancesToTerminate(
            running: running, ownPID: 200, ownBundleID: ownBundle)
        XCTAssertEqual(doomed.map(\.pid), [100, 101, 102])
    }

    /// Never reach outside our own bundle — a same-named process from another
    /// app must not be killed.
    func testOtherAppsAreLeftAlone() {
        let running = [inst(100, "com.apple.Safari"), inst(200, ownBundle)]
        XCTAssertTrue(SingleInstanceGuard.instancesToTerminate(
            running: running, ownPID: 200, ownBundleID: ownBundle).isEmpty)
    }

    func testUnidentifiedProcessesAreLeftAlone() {
        let running = [inst(100, nil), inst(200, ownBundle)]
        XCTAssertTrue(SingleInstanceGuard.instancesToTerminate(
            running: running, ownPID: 200, ownBundleID: ownBundle).isEmpty)
    }

    /// Guards against a self-terminating launch loop: our own pid can appear in
    /// the running list under our own bundle ID and must always be excluded.
    func testNeverTerminatesSelf() {
        let running = [inst(200, ownBundle)]
        let doomed = SingleInstanceGuard.instancesToTerminate(
            running: running, ownPID: 200, ownBundleID: ownBundle)
        XCTAssertFalse(doomed.contains(inst(200, ownBundle)))
    }

    /// A dev build launched from DerivedData carries the same bundle ID as the
    /// deployed copy — that is exactly the collision we are cleaning up, so it
    /// must be caught despite living at a different path.
    func testSameBundleIDFromADifferentPathIsTerminated() {
        let running = [inst(100, ownBundle), inst(200, ownBundle)]
        let doomed = SingleInstanceGuard.instancesToTerminate(
            running: running, ownPID: 200, ownBundleID: ownBundle)
        XCTAssertEqual(doomed.count, 1)
    }
}
