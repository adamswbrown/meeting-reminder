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

// MARK: - Instant Slack ping text builder
// Co-located here (rather than a new SlackPingTests.swift) to avoid pbxproj surgery;
// move to its own file if this grows. Times are asserted in Europe/London.
final class IntradaySlackPingTests: XCTestCase {
    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testTodayMeetingSaysTodayInLondonTime() {
        let now = at("2026-08-12T09:00:00Z")
        let start = at("2026-08-12T14:00:00Z")   // 15:00 Europe/London (BST)
        let msg = IntradaySlackPing.message(title: "Markerstudy Q&A", start: start, now: now)
        XCTAssertTrue(msg.contains("Markerstudy Q&A"), msg)
        XCTAssertTrue(msg.contains("@ 15:00 today"), msg)
    }

    func testTomorrowMeetingSaysTomorrow() {
        let now = at("2026-08-12T09:00:00Z")
        let start = at("2026-08-13T10:30:00Z")   // 11:30 BST, next day
        let msg = IntradaySlackPing.message(title: "Sync", start: start, now: now)
        XCTAssertTrue(msg.contains("tomorrow"), msg)
        XCTAssertTrue(msg.contains("11:30"), msg)
    }

    func testDistantMeetingUsesAbsoluteDate() {
        let now = at("2026-08-12T09:00:00Z")
        let start = at("2026-08-20T08:00:00Z")   // 8 days out
        let msg = IntradaySlackPing.message(title: "Board", start: start, now: now)
        XCTAssertFalse(msg.contains(" today"), msg)
        XCTAssertFalse(msg.contains("tomorrow"), msg)
        XCTAssertTrue(msg.contains("20 Aug"), msg)
    }

    func testTitleIsTrimmed() {
        let now = at("2026-08-12T09:00:00Z")
        let start = at("2026-08-12T14:00:00Z")
        let msg = IntradaySlackPing.message(title: "  Padded  ", start: start, now: now)
        XCTAssertTrue(msg.contains("*Padded*"), msg)
    }
}
