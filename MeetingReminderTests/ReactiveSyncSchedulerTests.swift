import XCTest
@testable import MeetingReminder

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

final class ReactiveSyncSchedulerTests: XCTestCase {
    let sched = ReactiveSyncScheduler(debounce: 30, floor: 120)

    func testFirstEverChangeFiresAfterDebounceOnly() {
        let change = iso("2026-06-12T10:00:00Z")
        XCTAssertEqual(sched.fireTime(changeAt: change, lastRunAt: nil),
                       change.addingTimeInterval(30))
    }

    func testChangeLongAfterLastRunFiresAfterDebounce() {
        let change = iso("2026-06-12T10:00:00Z")
        let lastRun = iso("2026-06-12T09:50:00Z")
        XCTAssertEqual(sched.fireTime(changeAt: change, lastRunAt: lastRun),
                       change.addingTimeInterval(30))
    }

    func testChangeInsideFloorIsDeferredToFloorBoundary() {
        let lastRun = iso("2026-06-12T10:00:00Z")
        let change = iso("2026-06-12T10:00:30Z")
        XCTAssertEqual(sched.fireTime(changeAt: change, lastRunAt: lastRun),
                       lastRun.addingTimeInterval(120))
    }

    func testDebounceWinsWhenItExceedsFloorBoundary() {
        let lastRun = iso("2026-06-12T10:00:00Z")
        let change = iso("2026-06-12T10:01:45Z")
        XCTAssertEqual(sched.fireTime(changeAt: change, lastRunAt: lastRun),
                       change.addingTimeInterval(30))
    }
}

/// Item A5: a calendar edit landing while a sync runs (or in its cooldown)
/// used to be dropped outright. It now earns one follow-up run — but only
/// one, since a run's own `.EKEventStoreChanged` echo is indistinguishable
/// from an edit and would otherwise loop forever.
final class ReactiveFollowUpGateTests: XCTestCase {
    let t0 = iso("2026-09-26T10:00:00Z")

    func testChangeIgnoredDuringARunSchedulesAFollowUp() {
        var gate = ReactiveFollowUpGate(echoWindow: 60)
        XCTAssertTrue(gate.ignoredChange(at: t0))
        XCTAssertTrue(gate.nextFireIsFollowUp)
    }

    func testEchoOfTheFollowUpRunIsDropped() {
        var gate = ReactiveFollowUpGate(echoWindow: 60)
        _ = gate.ignoredChange(at: t0)
        gate.fireStarting()
        XCTAssertFalse(gate.ignoredChange(at: t0.addingTimeInterval(40)), "echo during the follow-up")
        gate.fireFinished(ran: true, at: t0.addingTimeInterval(50))
        XCTAssertFalse(gate.ignoredChange(at: t0.addingTimeInterval(60)), "echo in its cooldown")
        XCTAssertFalse(gate.nextFireIsFollowUp)
    }

    func testLaterRunGetsItsOwnFollowUpAgain() {
        var gate = ReactiveFollowUpGate(echoWindow: 60)
        _ = gate.ignoredChange(at: t0)
        gate.fireStarting()
        gate.fireFinished(ran: true, at: t0.addingTimeInterval(50))
        // An hour later another run (e.g. the daily one) is in flight.
        XCTAssertTrue(gate.ignoredChange(at: t0.addingTimeInterval(3600)))
    }

    func testSkippedFollowUpStaysAFollowUp() {
        var gate = ReactiveFollowUpGate(echoWindow: 60)
        _ = gate.ignoredChange(at: t0)
        gate.fireStarting()
        gate.fireFinished(ran: false, at: t0.addingTimeInterval(30))
        XCTAssertTrue(gate.nextFireIsFollowUp)
    }

    func testNormalRunIsNotAFollowUp() {
        var gate = ReactiveFollowUpGate(echoWindow: 60)
        gate.fireStarting()
        XCTAssertTrue(gate.ignoredChange(at: t0), "edit during a normal run earns a follow-up")
        gate.fireFinished(ran: true, at: t0.addingTimeInterval(10))
        XCTAssertTrue(gate.nextFireIsFollowUp, "finishing the normal run keeps the pending follow-up")
    }
}
