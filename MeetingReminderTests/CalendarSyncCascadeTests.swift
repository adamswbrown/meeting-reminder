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
                        cascade: Bool = true, archive: Bool = true,
                        probe: CalendarSyncCascade.OccurrenceProbe = .unresolved) -> CalendarSyncCascade.Disappearance {
        CalendarSyncCascade.classifyDisappearance(
            hasMeetingNotes: manual, isRecurring: recurring,
            isReactive: reactive, cascadeEnabled: cascade, archiveEnabled: archive,
            occurrenceProbe: probe)
    }

    func testCleanCancellationCascades() {
        let d = decide(manual: false, recurring: false, reactive: false)
        XCTAssertEqual(d.syncState, "Orphaned")
        XCTAssertEqual(d.rowStatus, "Cancelled")
        XCTAssertTrue(d.cascadeBriefCancelled)
    }

    /// Regression (2026-09-07, Sascha Samvilian demo): a row whose only relation is a
    /// Pre-Call Briefing must cascade to Cancelled — the brief link is *what the cascade
    /// updates*, not evidence of manual work. Previously the caller folded the brief link
    /// into "manual relations", so every briefed meeting went Stale and the brief's
    /// Meeting Outcome was never set.
    func testBriefOnlyRowStillCascadesToCancelled() {
        // `hasMeetingNotes` is the only manual-work signal; a brief link is not passed in.
        let d = decide(manual: false, recurring: false, reactive: true)
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

    // MARK: Reactive recurring occurrence + EventKit probe

    /// A reactive run with no probe verdict still defers to the daily full run —
    /// the pre-probe behaviour, preserved.
    func testReactiveRecurringUnresolvedStillDefers() {
        let d = decide(manual: false, recurring: true, reactive: true, probe: .unresolved)
        XCTAssertTrue(d.skip)
    }

    /// EventKit confirms the series no longer claims that date → cascade now
    /// instead of waiting for 06:00.
    func testReactiveRecurringConfirmedGoneCascades() {
        let d = decide(manual: false, recurring: true, reactive: true, probe: .confirmedGone)
        XCTAssertFalse(d.skip)
        XCTAssertEqual(d.syncState, "Orphaned")
        XCTAssertEqual(d.rowStatus, "Cancelled")
        XCTAssertTrue(d.cascadeBriefCancelled)
    }

    /// A confirmed cancellation on a row carrying manual notes is still Stale,
    /// never Cancelled — the probe doesn't override the manual-work rule.
    func testReactiveRecurringConfirmedGoneWithNotesStaysStale() {
        let d = decide(manual: true, recurring: true, reactive: true, probe: .confirmedGone)
        XCTAssertEqual(d.syncState, "Stale")
        XCTAssertNil(d.rowStatus)
        XCTAssertFalse(d.cascadeBriefCancelled)
    }

    /// A full run ignores the probe entirely (it has the whole window).
    func testFullRunRecurringCascadesWithoutProbe() {
        let d = decide(manual: false, recurring: true, reactive: false, probe: .unresolved)
        XCTAssertEqual(d.rowStatus, "Cancelled")
    }

    // MARK: splitOccurrenceAppleID

    func testSplitOccurrenceAppleID() {
        let parts = CalendarSyncCascade.splitOccurrenceAppleID("ABC123_2026-09-17")
        XCTAssertEqual(parts?.externalID, "ABC123")
        XCTAssertEqual(parts?.day, "2026-09-17")
    }

    /// Series masters, non-recurring IDs and the legacy `/RID=` form aren't
    /// probeable — the caller must treat them as unresolved.
    func testSplitOccurrenceAppleIDRejectsNonOccurrences() {
        XCTAssertNil(CalendarSyncCascade.splitOccurrenceAppleID("ABC123"))
        XCTAssertNil(CalendarSyncCascade.splitOccurrenceAppleID("ABC123/RID=808905600"))
        XCTAssertNil(CalendarSyncCascade.splitOccurrenceAppleID("_2026-09-17"))
        XCTAssertNil(CalendarSyncCascade.splitOccurrenceAppleID("ABC123_2026-09"))
    }
}
