import XCTest
@testable import MeetingReminder

final class SnoozeUntilThresholdTests: XCTestCase {

    /// Keys we manipulate in these tests — cleared before and after each test so we
    /// never leak state into the real UserDefaults-backed toggles.
    private let keys = ["snoozeUntil10Enabled", "snoozeUntil5Enabled",
                        "snoozeUntil2Enabled", "snoozeUntil0Enabled"]

    override func setUp() {
        super.setUp()
        clearKeys()
    }

    override func tearDown() {
        clearKeys()
        super.tearDown()
    }

    private func clearKeys() {
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    // MARK: - Shape

    func testAllCasesAreTenFiveTwoZero() {
        XCTAssertEqual(SnoozeUntilThreshold.allCases.map(\.rawValue), [10, 5, 2, 0])
    }

    func testRawValueRoundTrip() {
        for t in SnoozeUntilThreshold.allCases {
            XCTAssertEqual(SnoozeUntilThreshold(rawValue: t.rawValue), t)
        }
    }

    func testLabelsNonEmpty() {
        for t in SnoozeUntilThreshold.allCases {
            XCTAssertFalse(t.displayName.isEmpty)
            XCTAssertFalse(t.buttonLabel.isEmpty)
        }
    }

    func testStartHasHumanLabels() {
        XCTAssertEqual(SnoozeUntilThreshold.start.buttonLabel, "Start")
        XCTAssertEqual(SnoozeUntilThreshold.start.displayName, "Until start")
        XCTAssertEqual(SnoozeUntilThreshold.fiveMin.buttonLabel, "5 min")
    }

    // MARK: - Defaults

    func testDefaultEnabledMap() {
        // 10 off by default; 5/2/0 on.
        XCTAssertFalse(SnoozeUntilThreshold.tenMin.defaultEnabled)
        XCTAssertTrue(SnoozeUntilThreshold.fiveMin.defaultEnabled)
        XCTAssertTrue(SnoozeUntilThreshold.twoMin.defaultEnabled)
        XCTAssertTrue(SnoozeUntilThreshold.start.defaultEnabled)
    }

    func testIsEnabledFallsBackToDefaultWhenUnset() {
        XCTAssertFalse(SnoozeUntilThreshold.tenMin.isEnabled)
        XCTAssertTrue(SnoozeUntilThreshold.fiveMin.isEnabled)
    }

    func testIsEnabledRespectsUserDefaults() {
        UserDefaults.standard.set(true, forKey: "snoozeUntil10Enabled")
        UserDefaults.standard.set(false, forKey: "snoozeUntil5Enabled")
        XCTAssertTrue(SnoozeUntilThreshold.tenMin.isEnabled)
        XCTAssertFalse(SnoozeUntilThreshold.fiveMin.isEnabled)
    }

    // MARK: - snoozeSeconds maths

    func testSnoozeSecondsForFiveMinWithTenMinutesRemaining() {
        // 10 min out, snooze until 5 min before → 5 min = 300s from now.
        let s = SnoozeUntilThreshold.fiveMin.snoozeSeconds(secondsUntilStart: 600)
        XCTAssertEqual(s, 300)
    }

    func testSnoozeSecondsForStartEqualsTimeRemaining() {
        let s = SnoozeUntilThreshold.start.snoozeSeconds(secondsUntilStart: 90)
        XCTAssertEqual(s, 90)
    }

    func testSnoozeSecondsNilWhenTargetAlreadyPassed() {
        // Meeting is 3 min out; "5 min before" is already in the past → no button.
        XCTAssertNil(SnoozeUntilThreshold.fiveMin.snoozeSeconds(secondsUntilStart: 180))
    }

    func testSnoozeSecondsNilWhenWithinMinLead() {
        // Target within the 20s minimum-lead guard → nil (would re-fire instantly).
        XCTAssertNil(SnoozeUntilThreshold.start.snoozeSeconds(secondsUntilStart: 15))
    }

    // MARK: - available()

    func testAvailableFiltersByEnabledAndFuture() {
        // Defaults: 10 off, 5/2/0 on. Meeting 7 min (420s) out.
        // 10-min target is in the past anyway; of the enabled ones 5/2/0 all future.
        let available = SnoozeUntilThreshold.available(secondsUntilStart: 420)
        XCTAssertEqual(available, [.fiveMin, .twoMin, .start])
    }

    func testAvailableDropsPassedThresholds() {
        // 3 min (180s) out: "5 min before" passed; 2 and start remain.
        let available = SnoozeUntilThreshold.available(secondsUntilStart: 180)
        XCTAssertEqual(available, [.twoMin, .start])
    }

    func testAvailableIncludesTenWhenEnabledAndFarEnoughOut() {
        UserDefaults.standard.set(true, forKey: "snoozeUntil10Enabled")
        // 12 min (720s) out — all four thresholds are future.
        let available = SnoozeUntilThreshold.available(secondsUntilStart: 720)
        XCTAssertEqual(available, [.tenMin, .fiveMin, .twoMin, .start])
    }

    func testAvailableEmptyWhenMeetingStarted() {
        XCTAssertTrue(SnoozeUntilThreshold.available(secondsUntilStart: 5).isEmpty)
    }
}
