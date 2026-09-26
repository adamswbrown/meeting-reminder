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
}
