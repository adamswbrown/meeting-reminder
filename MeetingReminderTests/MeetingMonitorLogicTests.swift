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

    func testBackToBackPicksAdjacentMeetingAlreadyStarted() {
        // A ends exactly when B starts; the 30s check tick runs ~20s after B began.
        let a = event("a", start: now.addingTimeInterval(-1820), minutes: 30)  // ended 20s ago
        let b = event("b", start: a.endDate)
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

    // MARK: - menuBarInProgress — ended long blocks don't hide the countdown

    func testMenuBarInProgressSkipsMeetingMarkedEnded() {
        let block = event("block", start: now.addingTimeInterval(-3600), minutes: 480)
        XCTAssertNil(MeetingMonitorLogic.menuBarInProgress(in: [block], endedIDs: ["block"]))
    }

    func testMenuBarInProgressFindsNextUnendedMeeting() {
        let block = event("block", start: now.addingTimeInterval(-3600), minutes: 480)
        let call = event("call", start: now.addingTimeInterval(-300), minutes: 30)
        XCTAssertEqual(
            MeetingMonitorLogic.menuBarInProgress(in: [block, call], endedIDs: ["block"])?.id,
            "call"
        )
    }

    func testMenuBarInProgressDefault() {
        let call = event("call", start: now.addingTimeInterval(-300), minutes: 30)
        XCTAssertEqual(MeetingMonitorLogic.menuBarInProgress(in: [call], endedIDs: [])?.id, "call")
    }

    // MARK: - CallEndGate — back-to-back meetings

    func testGateNotArmedAtJoin() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false, previousCallMayHoldMic: true, now: now)
        XCTAssertFalse(gate.isArmed)
    }

    func testGateArmsOnFirstMicActivityWhenJoinedFromIdle() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false, previousCallMayHoldMic: true, now: now)
        gate.observe(micActive: false, now: now.addingTimeInterval(5))
        XCTAssertFalse(gate.isArmed)
        gate.observe(micActive: true, now: now.addingTimeInterval(10))
        XCTAssertTrue(gate.isArmed)
    }

    func testPreviousCallStillHotDoesNotArm() {
        // Joined B while A's call still had the mic — A's audio must not count.
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: true, previousCallMayHoldMic: true, now: now)
        gate.observe(micActive: true, now: now.addingTimeInterval(5))
        XCTAssertFalse(gate.isArmed)
        // A hangs up: mic drops. Still not B's call.
        gate.observe(micActive: false, now: now.addingTimeInterval(10))
        XCTAssertFalse(gate.isArmed)
        // B's call picks up the mic: now armed.
        gate.observe(micActive: true, now: now.addingTimeInterval(15))
        XCTAssertTrue(gate.isArmed)
    }

    func testAlreadyInThisCallAtJoinArmsWhenNoOtherMeetingCouldHoldMic() {
        // Clicking Join on the in-call alert while already in this meeting's
        // call (true, true, false): the hang-up must still end the meeting.
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: true, previousCallMayHoldMic: false, now: now)
        gate.observe(micActive: true, now: now.addingTimeInterval(5))
        XCTAssertTrue(gate.isArmed)
        gate.observe(micActive: false, now: now.addingTimeInterval(10))
        XCTAssertTrue(gate.isArmed)
    }

    func testSeamlessCallSwitchArmsAfterContinuousActivity() {
        // Teams hold→join with no quiet poll: mic stays hot from A into B.
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: true, previousCallMayHoldMic: true, now: now)
        gate.observe(micActive: true, now: now.addingTimeInterval(60))
        XCTAssertFalse(gate.isArmed)
        gate.observe(micActive: true, now: now.addingTimeInterval(CallEndGate.continuousActiveArmAfter))
        XCTAssertTrue(gate.isArmed)
    }

    func testQuietResetsContinuousActivityClock() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: true, previousCallMayHoldMic: true, now: now)
        gate.observe(micActive: false, now: now.addingTimeInterval(5))   // A hung up
        gate.observe(micActive: false,
                     now: now.addingTimeInterval(CallEndGate.continuousActiveArmAfter + 5))
        XCTAssertFalse(gate.isArmed)
    }

    func testGateStaysArmedOnceArmed() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false, previousCallMayHoldMic: true, now: now)
        gate.observe(micActive: true, now: now)
        gate.observe(micActive: false, now: now.addingTimeInterval(5))
        XCTAssertTrue(gate.isArmed)
    }

    func testBeginResetsGate() {
        var gate = CallEndGate()
        gate.begin(micActiveAtJoin: false, previousCallMayHoldMic: true, now: now)
        gate.observe(micActive: true, now: now)
        gate.begin(micActiveAtJoin: true, previousCallMayHoldMic: true, now: now)
        XCTAssertFalse(gate.isArmed)
    }

    // MARK: - otherMeetingMayHoldMic

    func testOtherMeetingInProgressMayHoldMic() {
        let a = event("a", start: now.addingTimeInterval(-1500), minutes: 30)
        let b = event("b", start: now.addingTimeInterval(-60))
        XCTAssertTrue(MeetingMonitorLogic.otherMeetingMayHoldMic(joining: b, in: [a, b], now: now))
    }

    func testRecentlyEndedMeetingMayStillHoldMic() {
        // A ended 5 min ago on the calendar but may be overrunning.
        let a = event("a", start: now.addingTimeInterval(-2100), minutes: 30)
        let b = event("b", start: now.addingTimeInterval(-300))
        XCTAssertTrue(MeetingMonitorLogic.otherMeetingMayHoldMic(joining: b, in: [a, b], now: now))
    }

    func testNoOtherMeetingMeansHotMicIsThisCall() {
        let old = event("old", start: now.addingTimeInterval(-7200), minutes: 30)
        let b = event("b", start: now.addingTimeInterval(-600))
        let later = event("later", start: now.addingTimeInterval(1800))
        XCTAssertFalse(MeetingMonitorLogic.otherMeetingMayHoldMic(joining: b, in: [old, b, later], now: now))
    }
}
