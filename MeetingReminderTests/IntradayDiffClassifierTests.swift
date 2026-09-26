import XCTest
@testable import MeetingReminder

private func ev(_ title: String, _ startISO: String, id: String? = nil, uid: String? = nil) -> MeetingEvent {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    let start = f.date(from: startISO)!
    return MeetingEvent(id: id ?? "\(title)@\(startISO)", title: title,
                        startDate: start, endDate: start.addingTimeInterval(1800),
                        calendar: "Work", externalID: uid)
}

final class IntradayDiffClassifierTests: XCTestCase {

    func testOnlyAddedAreNewMeetings() {
        let d = IntradayDiffClassifier.classify(
            added: [ev("Sync", "2026-07-30T10:00:00Z")], removed: [])
        XCTAssertEqual(d.newMeetings.map(\.title), ["Sync"])
        XCTAssertTrue(d.reschedules.isEmpty)
        XCTAssertTrue(d.cancellations.isEmpty)
    }

    func testOnlyRemovedAreCancellations() {
        let d = IntradayDiffClassifier.classify(
            added: [], removed: [ev("Standup", "2026-07-30T14:00:00Z")])
        XCTAssertEqual(d.cancellations.map(\.title), ["Standup"])
        XCTAssertTrue(d.newMeetings.isEmpty)
        XCTAssertTrue(d.reschedules.isEmpty)
    }

    // Same title, different time → one reschedule; NOT a cancel + a new meeting.
    func testSameTitleDifferentTimeIsReschedule() {
        let old = ev("1:1 with Sam", "2026-07-30T14:00:00Z")
        let new = ev("1:1 with Sam", "2026-07-30T16:00:00Z")
        let d = IntradayDiffClassifier.classify(added: [new], removed: [old])
        XCTAssertEqual(d.reschedules.count, 1)
        XCTAssertEqual(d.reschedules.first?.old.startDate, old.startDate)
        XCTAssertEqual(d.reschedules.first?.new.startDate, new.startDate)
        XCTAssertTrue(d.newMeetings.isEmpty)
        XCTAssertTrue(d.cancellations.isEmpty)
    }

    // A reschedule alongside an unrelated new meeting: pair the move, keep the new one.
    func testMixedRescheduleAndNewMeeting() {
        let old = ev("Review", "2026-07-30T14:00:00Z")
        let moved = ev("Review", "2026-07-30T16:00:00Z")
        let brandNew = ev("Kickoff", "2026-07-30T11:00:00Z")
        let d = IntradayDiffClassifier.classify(added: [moved, brandNew], removed: [old])
        XCTAssertEqual(d.reschedules.count, 1)
        XCTAssertEqual(d.newMeetings.map(\.title), ["Kickoff"])
        XCTAssertTrue(d.cancellations.isEmpty)
    }

    // Same title AND same time is not a move — don't pair (treat as separate signals).
    func testSameTitleSameTimeNotPaired() {
        let a = ev("Ghost", "2026-07-30T14:00:00Z", id: "A")
        let b = ev("Ghost", "2026-07-30T14:00:00Z", id: "B")
        let d = IntradayDiffClassifier.classify(added: [a], removed: [b])
        XCTAssertTrue(d.reschedules.isEmpty)
        XCTAssertEqual(d.newMeetings.count, 1)
        XCTAssertEqual(d.cancellations.count, 1)
    }

    // Title differing only by case/whitespace still pairs.
    func testTitlePairingIsCaseAndWhitespaceInsensitive() {
        let old = ev("  Weekly Sync ", "2026-07-30T14:00:00Z")
        let new = ev("weekly sync", "2026-07-30T15:00:00Z")
        let d = IntradayDiffClassifier.classify(added: [new], removed: [old])
        XCTAssertEqual(d.reschedules.count, 1)
    }

    // MARK: Identity-aware pairing (C4)

    // Two different meetings that merely share a generic title (different iCal UIDs)
    // are a cancellation plus a genuinely new meeting — not a move.
    func testSameTitleDifferentUIDIsNotPaired() {
        let old = ev("Catch-up", "2026-07-30T10:00:00Z", uid: "UID-A")
        let other = ev("Catch-up", "2026-07-30T15:00:00Z", uid: "UID-B")
        let d = IntradayDiffClassifier.classify(added: [other], removed: [old])
        XCTAssertTrue(d.reschedules.isEmpty)
        XCTAssertEqual(d.newMeetings.map(\.externalID), ["UID-B"])
        XCTAssertEqual(d.cancellations.map(\.externalID), ["UID-A"])
    }

    // A one-off move keeps its UID → still a reschedule.
    func testSameTitleSameUIDIsReschedule() {
        let old = ev("Catch-up", "2026-07-30T10:00:00Z", uid: "UID-A")
        let moved = ev("Catch-up", "2026-07-30T15:00:00Z", uid: "UID-A")
        let d = IntradayDiffClassifier.classify(added: [moved], removed: [old])
        XCTAssertEqual(d.reschedules.count, 1)
    }

    // A detached recurring occurrence carries `<uid>/RID=<n>` — same series, so a move.
    func testDetachedOccurrenceOfSameSeriesIsReschedule() {
        let old = ev("Standup", "2026-07-30T10:00:00Z", uid: "SERIES-1")
        let moved = ev("Standup", "2026-07-30T11:00:00Z", uid: "SERIES-1/RID=807094800")
        let d = IntradayDiffClassifier.classify(added: [moved], removed: [old])
        XCTAssertEqual(d.reschedules.count, 1)
    }

    func testIsLikelyMoveRequiresMatchingIdentityWhenBothKnown() {
        let removed = ev("1:1", "2026-07-30T10:00:00Z", uid: "UID-A")
        XCTAssertTrue(IntradayDiffClassifier.isLikelyMove(removed: removed,
                                                          added: ev("1:1", "2026-07-30T12:00:00Z", uid: "UID-A")))
        XCTAssertFalse(IntradayDiffClassifier.isLikelyMove(removed: removed,
                                                           added: ev("1:1", "2026-07-30T12:00:00Z", uid: "UID-B")))
        // No UID on one side → title-only fallback (previous behaviour).
        XCTAssertTrue(IntradayDiffClassifier.isLikelyMove(removed: removed,
                                                          added: ev("1:1", "2026-07-30T12:00:00Z")))
    }

    // MARK: Withdrawing never-briefed meetings (C3)

    // A meeting still queued for a brief that vanishes is withdrawn — no brief, and no
    // "cancelled" notice for a meeting that was never announced.
    func testCancelledWhileQueuedIsWithdrawn() {
        let queued = ev("Intro call", "2026-07-30T14:00:00Z", id: "Q")
        let announced = ev("Board", "2026-07-30T15:00:00Z", id: "B")
        let diff = IntradayDiffClassifier.classify(added: [], removed: [queued, announced])
        let r = IntradayDiffClassifier.withdrawUnbriefed(diff, pendingBriefIDs: ["Q"])
        XCTAssertEqual(r.withdrawnIDs, ["Q"])
        XCTAssertEqual(r.diff.cancellations.map(\.id), ["B"])
        XCTAssertTrue(r.diff.newMeetings.isEmpty)
    }

    // A queued meeting that moves before it was briefed → brief the new time instead;
    // no "moved" notice.
    func testRescheduledWhileQueuedBecomesNewBrief() {
        let queued = ev("Intro call", "2026-07-30T14:00:00Z", id: "Q", uid: "U")
        let moved = ev("Intro call", "2026-07-30T16:00:00Z", id: "Q2", uid: "U")
        let diff = IntradayDiffClassifier.classify(added: [moved], removed: [queued])
        let r = IntradayDiffClassifier.withdrawUnbriefed(diff, pendingBriefIDs: ["Q"])
        XCTAssertEqual(r.withdrawnIDs, ["Q"])
        XCTAssertTrue(r.diff.reschedules.isEmpty)
        XCTAssertEqual(r.diff.newMeetings.map(\.id), ["Q2"])
    }

    func testWithdrawLeavesAnnouncedMeetingsAlone() {
        let old = ev("Review", "2026-07-30T14:00:00Z", id: "R", uid: "U")
        let moved = ev("Review", "2026-07-30T16:00:00Z", id: "R2", uid: "U")
        let diff = IntradayDiffClassifier.classify(added: [moved], removed: [old])
        let r = IntradayDiffClassifier.withdrawUnbriefed(diff, pendingBriefIDs: [])
        XCTAssertTrue(r.withdrawnIDs.isEmpty)
        XCTAssertEqual(r.diff.reschedules.count, 1)
    }

    // MARK: Burst guard (C2)

    func testBurstGuardAbsorbsFilterChange() {
        XCTAssertTrue(IntradayBurstGuard.shouldAbsorb(filterChanged: true, addedCount: 1, removedCount: 0))
    }

    func testBurstGuardAbsorbsOversizedBurst() {
        XCTAssertTrue(IntradayBurstGuard.shouldAbsorb(filterChanged: false,
                                                      addedCount: IntradayBurstGuard.maxChanges,
                                                      removedCount: 1))
    }

    func testBurstGuardPassesNormalChange() {
        XCTAssertFalse(IntradayBurstGuard.shouldAbsorb(filterChanged: false, addedCount: 1, removedCount: 1))
        XCTAssertFalse(IntradayBurstGuard.shouldAbsorb(filterChanged: false,
                                                       addedCount: IntradayBurstGuard.maxChanges,
                                                       removedCount: 0))
    }
}
