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

    private func decide(manual: Bool, recurring: Bool,
                        cascade: Bool = true, archive: Bool = true,
                        probe: CalendarSyncCascade.OccurrenceProbe = .unresolved) -> CalendarSyncCascade.Disappearance {
        CalendarSyncCascade.classifyDisappearance(
            hasMeetingNotes: manual, isRecurring: recurring,
            cascadeEnabled: cascade, archiveEnabled: archive,
            occurrenceProbe: probe)
    }

    func testCleanCancellationCascades() {
        let d = decide(manual: false, recurring: false)
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
        let d = decide(manual: false, recurring: false)
        XCTAssertEqual(d.syncState, "Orphaned")
        XCTAssertEqual(d.rowStatus, "Cancelled")
        XCTAssertTrue(d.cascadeBriefCancelled)
    }

    func testManualRelationsRowGoesStaleNotCancelled() {
        let d = decide(manual: true, recurring: false)
        XCTAssertEqual(d.syncState, "Stale")
        XCTAssertNil(d.rowStatus)              // never mark a manually-worked row Cancelled
        XCTAssertFalse(d.cascadeBriefCancelled)
    }

    /// Recurring orphans are gated by the probe in EVERY mode — an edited
    /// occurrence is alive under a new ID, and stamping the ghost row Cancelled
    /// is wrong whether a reactive or a full run notices it.
    func testRecurringSkippedWhenSiblingMayBeAlive() {
        let d = decide(manual: false, recurring: true, probe: .unresolved)
        XCTAssertTrue(d.skip)
    }

    func testRecurringSweptOnceSiblingRuledOut() {
        let d = decide(manual: false, recurring: true, probe: .confirmedGone)
        XCTAssertFalse(d.skip)
        XCTAssertEqual(d.rowStatus, "Cancelled")
    }

    func testCascadeDisabledStillWritesSyncStateWhenArchiveOn() {
        let d = decide(manual: false, recurring: false, cascade: false, archive: true)
        XCTAssertEqual(d.syncState, "Orphaned")
        XCTAssertNil(d.rowStatus)              // Status/brief writes are cascade-gated
        XCTAssertFalse(d.cascadeBriefCancelled)
    }

    func testBothDisabledSkips() {
        let d = decide(manual: false, recurring: false, cascade: false, archive: false)
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

    // MARK: Recurring occurrence + detached-sibling probe

    /// No verdict (or a live detached sibling) → never cascade. Applies in every
    /// mode: an edited occurrence is alive under a new ID, not cancelled.
    func testRecurringUnresolvedNeverCascades() {
        let d = decide(manual: false, recurring: true, probe: .unresolved)
        XCTAssertTrue(d.skip)
    }

    /// Nothing detached claims the date → a real cancellation, cascade it.
    func testRecurringConfirmedGoneCascades() {
        let d = decide(manual: false, recurring: true, probe: .confirmedGone)
        XCTAssertFalse(d.skip)
        XCTAssertEqual(d.syncState, "Orphaned")
        XCTAssertEqual(d.rowStatus, "Cancelled")
        XCTAssertTrue(d.cascadeBriefCancelled)
    }

    /// A confirmed cancellation on a row carrying manual notes is still Stale,
    /// never Cancelled — the probe doesn't override the manual-work rule.
    func testRecurringConfirmedGoneWithNotesStaysStale() {
        let d = decide(manual: true, recurring: true, probe: .confirmedGone)
        XCTAssertEqual(d.syncState, "Stale")
        XCTAssertNil(d.rowStatus)
        XCTAssertFalse(d.cascadeBriefCancelled)
    }

    /// A non-recurring orphan never consults the probe — unchanged behaviour.
    func testNonRecurringOrphanCascadesWithoutProbe() {
        let d = decide(manual: false, recurring: false, probe: .unresolved)
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

    // MARK: detachedOccurrence / hasLiveDetachedSibling
    //
    // Identifiers below are the real ones from the v3.5.1 false positive
    // (2026-09-17). `/RID=811848600` decodes to 2026-09-23T09:30:00Z — the
    // occurrence's ORIGINAL start, which is what anchors it to a ghost row.

    private let sccUID = "D3C55E60-BFF4-4271-9B7C-3B2926EB435F"

    func testDetachedOccurrenceDecodesOriginalStart() {
        let d = CalendarSyncCascade.detachedOccurrence(fromID: "\(sccUID)/RID=811848600")
        XCTAssertEqual(d?.seriesUID, sccUID)
        XCTAssertEqual(d?.originalStart, iso("2026-09-23T09:30:00Z"))
    }

    func testDetachedOccurrenceToleratesTrailingDaySuffix() {
        let d = CalendarSyncCascade.detachedOccurrence(fromID: "\(sccUID)/RID=811848600_2026-09-23")
        XCTAssertEqual(d?.originalStart, iso("2026-09-23T09:30:00Z"))
    }

    func testDetachedOccurrenceRejectsNonDetachedIDs() {
        XCTAssertNil(CalendarSyncCascade.detachedOccurrence(fromID: sccUID))
        XCTAssertNil(CalendarSyncCascade.detachedOccurrence(fromID: "\(sccUID)_2026-09-23"))
        XCTAssertNil(CalendarSyncCascade.detachedOccurrence(fromID: "\(sccUID)/RID="))
        XCTAssertNil(CalendarSyncCascade.detachedOccurrence(fromID: "\(sccUID)/RID=notanumber"))
        XCTAssertNil(CalendarSyncCascade.detachedOccurrence(fromID: "/RID=811848600"))
    }

    /// The exact regression: the ghost row's day is still claimed by a live
    /// detached sibling, so it must NOT be treated as cancelled.
    func testLiveDetachedSiblingDetected() {
        let seen: Set<String> = ["\(sccUID)/RID=811848600", "unrelated-id_2026-09-23"]
        XCTAssertTrue(CalendarSyncCascade.hasLiveDetachedSibling(
            orphanID: "\(sccUID)_2026-09-23", among: seen))
    }

    /// A sibling of the same series anchored to a *different* day says nothing
    /// about this occurrence.
    func testDetachedSiblingOnAnotherDayIgnored() {
        let seen: Set<String> = ["\(sccUID)/RID=811243800"]   // 2026-09-16
        XCTAssertFalse(CalendarSyncCascade.hasLiveDetachedSibling(
            orphanID: "\(sccUID)_2026-09-23", among: seen))
    }

    /// A detached sibling of a *different* series on the same day is not ours.
    func testDetachedSiblingOfOtherSeriesIgnored() {
        let seen: Set<String> = ["CECC1C61-18C9-4E33-AD4B-BFA832F3B84D/RID=811848600"]
        XCTAssertFalse(CalendarSyncCascade.hasLiveDetachedSibling(
            orphanID: "\(sccUID)_2026-09-23", among: seen))
    }

    /// The genuine cancellation from the same morning: nothing detached claims
    /// the day, so the cascade is free to fire.
    func testGenuineCancellationHasNoSibling() {
        let seen: Set<String> = ["CECC1C61-18C9-4E33-AD4B-BFA832F3B84D",
                                 "CECC1C61-18C9-4E33-AD4B-BFA832F3B84D_2026-09-24"]
        XCTAssertFalse(CalendarSyncCascade.hasLiveDetachedSibling(
            orphanID: "CECC1C61-18C9-4E33-AD4B-BFA832F3B84D_2026-09-17", among: seen))
    }

    func testHasLiveDetachedSiblingIgnoresNonOccurrenceOrphans() {
        XCTAssertFalse(CalendarSyncCascade.hasLiveDetachedSibling(
            orphanID: sccUID, among: ["\(sccUID)/RID=811848600"]))
    }
}
