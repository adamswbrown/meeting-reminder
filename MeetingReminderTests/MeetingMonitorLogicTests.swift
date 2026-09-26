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
}
