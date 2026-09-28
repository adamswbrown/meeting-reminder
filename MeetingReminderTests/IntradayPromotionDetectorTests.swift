import XCTest
@testable import MeetingReminder

private func ev(_ title: String, id: String = "E1", hold: Bool = false) -> MeetingEvent {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    return MeetingEvent(id: id, title: title, startDate: start, endDate: start.addingTimeInterval(1800),
                        calendar: "Work", isHold: hold)
}

final class IntradayPromotionDetectorTests: XCTestCase {

    private func promoted(_ before: MeetingEvent, _ after: MeetingEvent) -> [String] {
        IntradayPromotionDetector.promoted(previous: [before.id: before], current: [after]).map(\.title)
    }

    // Northumbria, 2026-09-28: same event, Free → busy.
    func testFreeHoldTurningBusyIsPromoted() {
        XCTAssertEqual(promoted(ev("Northumbria Police | Dr Migrate", hold: true),
                                ev("Northumbria Police | Dr Migrate")),
                       ["Northumbria Police | Dr Migrate"])
    }

    func testPlaceholderRenamedIsPromoted() {
        XCTAssertEqual(promoted(ev("PLACEHOLDER – Humberside kick-off"), ev("Humberside kick-off")),
                       ["Humberside kick-off"])
    }

    func testRenamedButStillFreeIsNotPromoted() {
        XCTAssertTrue(promoted(ev("Placeholder", hold: true), ev("Real title", hold: true)).isEmpty)
    }

    func testBusyMeetingGoingFreeIsNotPromoted() {
        XCTAssertTrue(promoted(ev("Sync"), ev("Sync", hold: true)).isEmpty)
    }

    func testUnchangedBusyMeetingIsNotPromoted() {
        XCTAssertTrue(promoted(ev("Sync"), ev("Sync")).isEmpty)
    }

    // Brand-new ids are the plain diff's job, not a promotion.
    func testNewIdIsNotPromoted() {
        XCTAssertTrue(promoted(ev("Hold", id: "A", hold: true), ev("Kickoff", id: "B")).isEmpty)
    }
}
