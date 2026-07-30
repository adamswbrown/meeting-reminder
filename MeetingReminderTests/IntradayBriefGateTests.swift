import XCTest
@testable import MeetingReminder

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

/// Dates below are UTC. 2026-07-30 is a Thursday (weekday 5), 2026-07-29 a Wednesday.
final class IntradayBriefGateTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func gate() -> IntradayBriefGate {
        IntradayBriefGate(calendar: utc, workStartHour: 9, workEndHour: 17,
                          workdays: 2...6, startedGrace: 300)
    }

    // MARK: - The 09:00 dead-zone regression (the reported bug)

    /// Before the window opens, a meeting that starts *at* the open must WAIT for the
    /// window — not fire early outside hours, not be dropped.
    func testMeetingAtWindowOpen_beforeOpen_waitsForOpen() {
        let d = gate().decide(meetingStart: iso("2026-07-30T09:00:00Z"),
                              now:          iso("2026-07-30T08:25:00Z"))
        XCTAssertEqual(d, .waitUntil(iso("2026-07-30T09:00:00Z")))
    }

    /// At the open, that same meeting FIRES. Previously the already-started drop killed
    /// it here (start == now); the grace now protects it. This is the core fix.
    func testMeetingAtWindowOpen_atOpen_firesNotDropped() {
        let d = gate().decide(meetingStart: iso("2026-07-30T09:00:00Z"),
                              now:          iso("2026-07-30T09:00:00Z").addingTimeInterval(0.5))
        XCTAssertEqual(d, .fireNow)
    }

    // MARK: - Imminent exemption (A)

    /// A meeting that starts *before* the window opens can't wait — brief it now even
    /// though it's outside working hours (the only chance to brief before it starts).
    func testMeetingBeforeWindowOpen_firesNowOutsideHours() {
        let d = gate().decide(meetingStart: iso("2026-07-30T08:30:00Z"),
                              now:          iso("2026-07-30T08:00:00Z"))
        XCTAssertEqual(d, .fireNow)
    }

    /// An evening booking for the next morning's 09:00 waits for the window — no
    /// antisocial-hours Slack the night before.
    func testEveningBookingForNextMorning_waitsForWindow() {
        let d = gate().decide(meetingStart: iso("2026-07-30T09:00:00Z"),
                              now:          iso("2026-07-29T20:00:00Z"))
        XCTAssertEqual(d, .waitUntil(iso("2026-07-30T09:00:00Z")))
    }

    // MARK: - In-hours normal

    func testInHoursUpcoming_firesNow() {
        let d = gate().decide(meetingStart: iso("2026-07-30T10:30:00Z"),
                              now:          iso("2026-07-30T10:00:00Z"))
        XCTAssertEqual(d, .fireNow)
    }

    // MARK: - Non-imminent early booking (A defers)

    /// Booked at 02:00 for 15:00 the same day: not imminent, so it waits for 09:00.
    func testNonImminentEarlyBooking_deferredToWindow() {
        let d = gate().decide(meetingStart: iso("2026-07-30T15:00:00Z"),
                              now:          iso("2026-07-30T02:00:00Z"))
        XCTAssertEqual(d, .waitUntil(iso("2026-07-30T09:00:00Z")))
    }

    // MARK: - Already-started grace (C)

    /// Just started (2 min ago), still within grace, in hours → still worth briefing.
    func testJustStartedWithinGrace_firesNow() {
        let d = gate().decide(meetingStart: iso("2026-07-30T10:00:00Z"),
                              now:          iso("2026-07-30T10:02:00Z"))
        XCTAssertEqual(d, .fireNow)
    }

    /// Started 10 min ago, well past the grace → drop (no longer a pre-call brief).
    func testStartedBeyondGrace_dropped() {
        let d = gate().decide(meetingStart: iso("2026-07-30T10:00:00Z"),
                              now:          iso("2026-07-30T10:10:00Z"))
        XCTAssertEqual(d, .drop)
    }
}
