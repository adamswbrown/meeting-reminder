import XCTest
@testable import MeetingReminder

final class CalendarSyncCascadeTests: XCTestCase {

    // MARK: briefPageID(fromRelation:)

    func testBriefPageIDReturnsFirstRelationID() {
        let prop: [String: Any] = ["relation": [["id": "abc-123"], ["id": "def-456"]]]
        XCTAssertEqual(CalendarSyncCascade.briefPageID(fromRelation: prop), "abc-123")
    }

    func testBriefPageIDNilWhenEmpty() {
        XCTAssertNil(CalendarSyncCascade.briefPageID(fromRelation: ["relation": [[String: Any]]()]))
        XCTAssertNil(CalendarSyncCascade.briefPageID(fromRelation: nil))
        XCTAssertNil(CalendarSyncCascade.briefPageID(fromRelation: ["select": ["name": "x"]]))
    }

    // MARK: isRecurringAppleID

    func testRecurringAppleIDDetectsDateSuffix() {
        XCTAssertTrue(CalendarSyncCascade.isRecurringAppleID("XYZ_2026-08-12"))
    }

    func testRecurringAppleIDDetectsRID() {
        XCTAssertTrue(CalendarSyncCascade.isRecurringAppleID("040000008200E000/RID=20260812"))
    }

    func testRecurringAppleIDFalseForPlainUUID() {
        XCTAssertFalse(CalendarSyncCascade.isRecurringAppleID("0277BA37-EDB2-46DF-B159-D97DEDC48C5E"))
    }
}
