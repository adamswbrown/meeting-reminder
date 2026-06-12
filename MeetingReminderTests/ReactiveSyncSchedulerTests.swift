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
