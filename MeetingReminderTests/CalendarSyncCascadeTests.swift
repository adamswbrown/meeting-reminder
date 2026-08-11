import XCTest
@testable import MeetingReminder

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

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

    // MARK: classifyDisappearance

    private func decide(manual: Bool, recurring: Bool, reactive: Bool,
                        cascade: Bool = true, archive: Bool = true) -> CalendarSyncCascade.Disappearance {
        CalendarSyncCascade.classifyDisappearance(
            hasManualRelations: manual, isRecurring: recurring,
            isReactive: reactive, cascadeEnabled: cascade, archiveEnabled: archive)
    }

    func testCleanCancellationCascades() {
        let d = decide(manual: false, recurring: false, reactive: false)
        XCTAssertEqual(d.syncState, "Orphaned")
        XCTAssertEqual(d.rowStatus, "Cancelled")
        XCTAssertTrue(d.cascadeBriefCancelled)
    }

    func testManualRelationsRowGoesStaleNotCancelled() {
        let d = decide(manual: true, recurring: false, reactive: false)
        XCTAssertEqual(d.syncState, "Stale")
        XCTAssertNil(d.rowStatus)              // never mark a manually-worked row Cancelled
        XCTAssertFalse(d.cascadeBriefCancelled)
    }

    func testRecurringSkippedOnReactive() {
        let d = decide(manual: false, recurring: true, reactive: true)
        XCTAssertTrue(d.skip)                  // moved recurring occurrence — not a cancellation
    }

    func testRecurringSweptOnFullRun() {
        let d = decide(manual: false, recurring: true, reactive: false)
        XCTAssertFalse(d.skip)
        XCTAssertEqual(d.rowStatus, "Cancelled")
    }

    func testCascadeDisabledStillWritesSyncStateWhenArchiveOn() {
        let d = decide(manual: false, recurring: false, reactive: false, cascade: false, archive: true)
        XCTAssertEqual(d.syncState, "Orphaned")
        XCTAssertNil(d.rowStatus)              // Status/brief writes are cascade-gated
        XCTAssertFalse(d.cascadeBriefCancelled)
    }

    func testBothDisabledSkips() {
        let d = decide(manual: false, recurring: false, reactive: false, cascade: false, archive: false)
        XCTAssertTrue(d.skip)
    }

    // MARK: isCancelledStatus

    func testIsCancelledStatusTrueForCancelled() {
        XCTAssertTrue(CalendarSyncCascade.isCancelledStatus(["select": ["name": "Cancelled"]]))
    }

    func testIsCancelledStatusFalseForOther() {
        XCTAssertFalse(CalendarSyncCascade.isCancelledStatus(["select": ["name": "Upcoming"]]))
        XCTAssertFalse(CalendarSyncCascade.isCancelledStatus(nil))
    }

    // MARK: startChanged

    func testDateChangedDetectsMove() {
        let old = iso("2026-08-11T13:00:00Z")
        let new = iso("2026-08-12T08:00:00Z")
        XCTAssertTrue(CalendarSyncCascade.startChanged(incoming: new, existing: old))
        XCTAssertFalse(CalendarSyncCascade.startChanged(incoming: old, existing: old))
        XCTAssertFalse(CalendarSyncCascade.startChanged(incoming: new, existing: nil))
    }
}
