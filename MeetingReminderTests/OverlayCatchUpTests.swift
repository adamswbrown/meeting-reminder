import XCTest
@testable import MeetingReminder

final class OverlayCatchUpTests: XCTestCase {

    /// Convenience wrapper with the "happy path" defaults: a meeting that
    /// started 3 minutes ago, in progress, never shown, not snoozed, not the
    /// current meeting, blocking allowed.
    private func fire(
        timeUntilStart: TimeInterval = -180,
        isInProgress: Bool = true,
        hasEnded: Bool = false,
        alreadyShown: Bool = false,
        isSnoozed: Bool = false,
        isCurrentMeeting: Bool = false,
        blockingAllowed: Bool = true
    ) -> Bool {
        OverlayCatchUp.shouldFire(
            timeUntilStart: timeUntilStart,
            isInProgress: isInProgress,
            hasEnded: hasEnded,
            alreadyShown: alreadyShown,
            isSnoozed: isSnoozed,
            isCurrentMeeting: isCurrentMeeting,
            blockingAllowed: blockingAllowed
        )
    }

    // MARK: - Fires

    func testFiresForRecentlyStartedUnjoinedMeeting() {
        // The core case: app launched/redeployed a few minutes into a meeting
        // it never nudged and the user hasn't joined via the app.
        XCTAssertTrue(fire(timeUntilStart: -180))
    }

    func testFiresJustPastTheSixtySecondWindow() {
        XCTAssertTrue(fire(timeUntilStart: -61))
    }

    func testFiresNearEndOfCatchUpWindow() {
        XCTAssertTrue(fire(timeUntilStart: -(OverlayCatchUp.window - 1)))
    }

    // MARK: - Does not fire

    func testDoesNotFireWithinTheJustStartedWindow() {
        // 0…-60s is already handled by the main loop; catch-up must not double-fire.
        XCTAssertFalse(fire(timeUntilStart: -30))
    }

    func testDoesNotFireBeforeStart() {
        // Pre-meeting window is the main loop's job.
        XCTAssertFalse(fire(timeUntilStart: 120, isInProgress: false))
    }

    func testDoesNotFireBeyondCatchUpWindow() {
        // Started too long ago — the user is settled in; don't nudge.
        XCTAssertFalse(fire(timeUntilStart: -(OverlayCatchUp.window + 1)))
    }

    func testDoesNotFireWhenAlreadyShown() {
        XCTAssertFalse(fire(alreadyShown: true))
    }

    func testDoesNotFireWhenSnoozed() {
        XCTAssertFalse(fire(isSnoozed: true))
    }

    func testDoesNotFireWhenAlreadyCurrentMeeting() {
        XCTAssertFalse(fire(isCurrentMeeting: true))
    }

    func testDoesNotFireWhenEnded() {
        XCTAssertFalse(fire(isInProgress: false, hasEnded: true))
    }

    func testDoesNotFireWhenBlockingDisabled() {
        XCTAssertFalse(fire(blockingAllowed: false))
    }

    func testDoesNotFireWhenNotInProgress() {
        XCTAssertFalse(fire(isInProgress: false))
    }
}
