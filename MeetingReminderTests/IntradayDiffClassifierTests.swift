import XCTest
@testable import MeetingReminder

private func ev(_ title: String, _ startISO: String, id: String? = nil) -> MeetingEvent {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    let start = f.date(from: startISO)!
    return MeetingEvent(id: id ?? "\(title)@\(startISO)", title: title,
                        startDate: start, endDate: start.addingTimeInterval(1800),
                        calendar: "Work")
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
}
