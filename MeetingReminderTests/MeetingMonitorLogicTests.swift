import XCTest
@testable import MeetingReminder

final class MeetingMonitorLogicTests: XCTestCase {

    private func event(
        _ id: String,
        start: Date,
        minutes: Double = 30
    ) -> MeetingEvent {
        MeetingEvent(
            id: id,
            title: id,
            startDate: start,
            endDate: start.addingTimeInterval(minutes * 60),
            calendar: "Test"
        )
    }

    // MARK: - refreshed(_:from:) — stale in-progress snapshot

    func testRefreshedPicksUpExtendedEndDate() {
        let start = Date().addingTimeInterval(-3000)
        let joined = event("a", start: start, minutes: 45)        // ended 5 min ago
        let extended = event("a", start: start, minutes: 90)      // organiser extended it
        let fresh = MeetingMonitorLogic.refreshed(joined, from: [extended])
        XCTAssertEqual(fresh.endDate, extended.endDate)
        XCTAssertFalse(fresh.hasEnded)
    }

    func testRefreshedKeepsSnapshotWhenEventMissing() {
        // Ad-hoc meetings and meetings cancelled mid-call aren't in the live list.
        let joined = event("adhoc-1", start: Date(), minutes: 60)
        let fresh = MeetingMonitorLogic.refreshed(joined, from: [event("b", start: Date())])
        XCTAssertEqual(fresh, joined)
    }

    // MARK: - CallEndGate — back-to-back meetings

    func testGateNotArmedAtJoin() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false)
        XCTAssertFalse(gate.isArmed)
    }

    func testGateArmsOnFirstMicActivityWhenJoinedFromIdle() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false)
        gate.observe(micActive: false)
        XCTAssertFalse(gate.isArmed)
        gate.observe(micActive: true)
        XCTAssertTrue(gate.isArmed)
    }

    func testPreviousCallStillHotDoesNotArm() {
        // Joined B while A's call still had the mic — A's audio must not count.
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: true)
        gate.observe(micActive: true)
        XCTAssertFalse(gate.isArmed)
        // A hangs up: mic drops. Still not B's call.
        gate.observe(micActive: false)
        XCTAssertFalse(gate.isArmed)
        // B's call picks up the mic: now armed.
        gate.observe(micActive: true)
        XCTAssertTrue(gate.isArmed)
    }

    func testGateStaysArmedOnceArmed() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false)
        gate.observe(micActive: true)
        gate.observe(micActive: false)
        XCTAssertTrue(gate.isArmed)
    }

    func testBeginResetsGate() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false)
        gate.observe(micActive: true)
        gate.begin(micActiveAtJoin: true)
        XCTAssertFalse(gate.isArmed)
    }
}
