import EventKit
import XCTest
@testable import MeetingReminder

final class CalendarEventInclusionTests: XCTestCase {

    private func include(
        isAllDay: Bool = false,
        status: EKEventStatus = .confirmed,
        me: EKParticipantStatus? = nil,
        calendarID: String = "cal-A",
        enabled: Set<String> = []
    ) -> Bool {
        CalendarEventInclusion.shouldInclude(
            isAllDay: isAllDay, status: status, myParticipantStatus: me,
            calendarID: calendarID, enabledCalendarIDs: enabled)
    }

    // The bug this fixes: an organiser-cancelled event lingers in the store as
    // `.canceled` and must NOT show in the menu bar.
    func testCancelledEventExcluded() {
        XCTAssertFalse(include(status: .canceled))
    }

    func testAllDayExcluded() {
        XCTAssertFalse(include(isAllDay: true))
    }

    func testDeclinedExcluded() {
        XCTAssertFalse(include(me: .declined))
    }

    func testNormalConfirmedIncluded() {
        XCTAssertTrue(include(status: .confirmed))
    }

    // `.none`/`.tentative` are ordinary events (Exchange often reports `.none`).
    func testTentativeAndNoneStatusIncluded() {
        XCTAssertTrue(include(status: .none))
        XCTAssertTrue(include(status: .tentative))
    }

    // Empty enabled-list = monitor everything.
    func testEmptyEnabledListIncludesAll() {
        XCTAssertTrue(include(calendarID: "anything", enabled: []))
    }

    func testEnabledListExcludesOtherCalendars() {
        XCTAssertFalse(include(calendarID: "cal-B", enabled: ["cal-A"]))
    }

    func testEnabledListIncludesMatchingCalendar() {
        XCTAssertTrue(include(calendarID: "cal-A", enabled: ["cal-A"]))
    }

    // A cancelled event on an enabled calendar is still excluded — cancellation wins.
    func testCancelledExcludedEvenOnEnabledCalendar() {
        XCTAssertFalse(include(status: .canceled, calendarID: "cal-A", enabled: ["cal-A"]))
    }
}
