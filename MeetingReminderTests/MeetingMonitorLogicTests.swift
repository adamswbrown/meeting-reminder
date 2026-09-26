import XCTest
@testable import MeetingReminder

final class MeetingMonitorLogicTests: XCTestCase {

    private func event(
        _ id: String,
        start: Date,
        minutes: Double = 30
    ) -> MeetingEvent {
        MeetingEvent(
            id: id,
            title: id,
            startDate: start,
            endDate: start.addingTimeInterval(minutes * 60),
            calendar: "Test"
        )
    }

    // MARK: - refreshed(_:from:) — stale in-progress snapshot

    func testRefreshedPicksUpExtendedEndDate() {
        let start = Date().addingTimeInterval(-3000)
        let joined = event("a", start: start, minutes: 45)        // ended 5 min ago
        let extended = event("a", start: start, minutes: 90)      // organiser extended it
        let fresh = MeetingMonitorLogic.refreshed(joined, from: [extended])
        XCTAssertEqual(fresh.endDate, extended.endDate)
        XCTAssertFalse(fresh.hasEnded)
    }

    func testRefreshedKeepsSnapshotWhenEventMissing() {
        // Ad-hoc meetings and meetings cancelled mid-call aren't in the live list.
        let joined = event("adhoc-1", start: Date(), minutes: 60)
        let fresh = MeetingMonitorLogic.refreshed(joined, from: [event("b", start: Date())])
        XCTAssertEqual(fresh, joined)
    }

    // MARK: - tiersAfterSnooze — no banner/beep replay

    func testSnoozeKeepsFiredLowerTiers() {
        let fired: Set<Int> = [AlertTier.ambient.rawValue, AlertTier.banner.rawValue, AlertTier.urgent.rawValue]
        XCTAssertEqual(MeetingMonitorLogic.tiersAfterSnooze(fired), fired)
    }

    func testSnoozeReleasesLastChanceTier() {
        let fired: Set<Int> = [AlertTier.banner.rawValue, AlertTier.lastChance.rawValue]
        XCTAssertEqual(MeetingMonitorLogic.tiersAfterSnooze(fired), [AlertTier.banner.rawValue])
    }

    func testSnoozeWithNothingFired() {
        XCTAssertNil(MeetingMonitorLogic.tiersAfterSnooze(nil))
    }

    // MARK: - shouldKeepSnooze — expired-snooze re-fire

    private let now = Date()

    func testActiveSnoozeKept() {
        XCTAssertTrue(MeetingMonitorLogic.shouldKeepSnooze(
            until: now.addingTimeInterval(30), timeUntilStart: 60, now: now))
    }

    func testExpiredSnoozeKeptForRecentlyStartedMeeting() {
        // Snooze ran out after the meeting slipped past the -60s window —
        // the entry must survive so the re-fire branch can bring the overlay back.
        XCTAssertTrue(MeetingMonitorLogic.shouldKeepSnooze(
            until: now.addingTimeInterval(-5), timeUntilStart: -120, now: now))
    }

    func testExpiredSnoozeDroppedForFutureMeeting() {
        // The normal pre-meeting window handles it; a lingering entry would
        // block the catch-up and last-chance paths.
        XCTAssertFalse(MeetingMonitorLogic.shouldKeepSnooze(
            until: now.addingTimeInterval(-5), timeUntilStart: 120, now: now))
    }

    func testExpiredSnoozeDroppedPastRefireWindow() {
        XCTAssertFalse(MeetingMonitorLogic.shouldKeepSnooze(
            until: now.addingTimeInterval(-5),
            timeUntilStart: -(MeetingMonitorLogic.snoozeRefireWindow + 1),
            now: now))
    }

    func testExpiredSnoozeDroppedWhenEventGone() {
        XCTAssertFalse(MeetingMonitorLogic.shouldKeepSnooze(
            until: now.addingTimeInterval(-5), timeUntilStart: nil, now: now))
    }

    // MARK: - CalendarService.nextBackToBack — break overlay target

    func testBackToBackPicksUpcomingMeeting() {
        let a = event("a", start: now.addingTimeInterval(-1800), minutes: 30)  // ends now
        let b = event("b", start: now.addingTimeInterval(120))
        XCTAssertEqual(CalendarService.nextBackToBack(after: a, in: [a, b], now: now)?.id, "b")
    }

    func testBackToBackSkipsOverlappingMeetingAlreadyStarted() {
        // c overlapped a and has already started — not a "next" meeting to break before.
        let a = event("a", start: now.addingTimeInterval(-1800), minutes: 30)
        let c = event("c", start: now.addingTimeInterval(-600), minutes: 60)
        let b = event("b", start: now.addingTimeInterval(60))
        XCTAssertEqual(CalendarService.nextBackToBack(after: a, in: [a, c, b], now: now)?.id, "b")
    }

    func testBackToBackSkipsFinishedMeeting() {
        let a = event("a", start: now.addingTimeInterval(-3600), minutes: 60)
        let done = event("done", start: now.addingTimeInterval(-900), minutes: 10)
        XCTAssertNil(CalendarService.nextBackToBack(after: a, in: [a, done], now: now))
    }

    func testBackToBackNilWhenGapIsABreak() {
        let a = event("a", start: now.addingTimeInterval(-1800), minutes: 30)
        let b = event("b", start: now.addingTimeInterval(900))
        XCTAssertNil(CalendarService.nextBackToBack(after: a, in: [a, b], now: now))
    }

    // MARK: - CallEndGate — back-to-back meetings

    func testGateNotArmedAtJoin() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false)
        XCTAssertFalse(gate.isArmed)
    }

    func testGateArmsOnFirstMicActivityWhenJoinedFromIdle() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false)
        gate.observe(micActive: false)
        XCTAssertFalse(gate.isArmed)
        gate.observe(micActive: true)
        XCTAssertTrue(gate.isArmed)
    }

    func testPreviousCallStillHotDoesNotArm() {
        // Joined B while A's call still had the mic — A's audio must not count.
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: true)
        gate.observe(micActive: true)
        XCTAssertFalse(gate.isArmed)
        // A hangs up: mic drops. Still not B's call.
        gate.observe(micActive: false)
        XCTAssertFalse(gate.isArmed)
        // B's call picks up the mic: now armed.
        gate.observe(micActive: true)
        XCTAssertTrue(gate.isArmed)
    }

    func testGateStaysArmedOnceArmed() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false)
        gate.observe(micActive: true)
        gate.observe(micActive: false)
        XCTAssertTrue(gate.isArmed)
    }

    func testBeginResetsGate() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false)
        gate.observe(micActive: true)
        gate.begin(micActiveAtJoin: true)
        XCTAssertFalse(gate.isArmed)
    }
}
