import XCTest
@testable import MeetingReminder

/// Regression for the 2026-09-04 → 2026-09-07 outage: every intraday run failed with
/// "FAILED to launch /usr/local/bin/claude: The file “claude” doesn’t exist" after an
/// npm reinstall moved the CLI to ~/.npm-global/bin. The service must look in the
/// well-known install locations, not a single hardcoded path.
final class ClaudeCLILocatorTests: XCTestCase {

    private let home = "/Users/test"

    func testExplicitOverrideWinsWhenItExists() {
        let r = ClaudeCLILocator.resolve(override: "/custom/claude", home: home) { $0 == "/custom/claude" || $0 == "/usr/local/bin/claude" }
        XCTAssertEqual(r, "/custom/claude")
    }

    func testMissingOverrideFallsBackToKnownLocation() {
        let r = ClaudeCLILocator.resolve(override: "/custom/claude", home: home) { $0 == "/Users/test/.npm-global/bin/claude" }
        XCTAssertEqual(r, "/Users/test/.npm-global/bin/claude")
    }

    func testEmptyOverrideIsIgnored() {
        let r = ClaudeCLILocator.resolve(override: "", home: home) { $0 == "/usr/local/bin/claude" }
        XCTAssertEqual(r, "/usr/local/bin/claude")
    }

    func testNpmGlobalIsFoundWhenUsrLocalIsGone() {
        let r = ClaudeCLILocator.resolve(override: nil, home: home) { $0 == "/Users/test/.npm-global/bin/claude" }
        XCTAssertEqual(r, "/Users/test/.npm-global/bin/claude")
    }

    func testHomebrewAndLocalBinAreCandidates() {
        XCTAssertEqual(ClaudeCLILocator.resolve(override: nil, home: home) { $0 == "/opt/homebrew/bin/claude" }, "/opt/homebrew/bin/claude")
        XCTAssertEqual(ClaudeCLILocator.resolve(override: nil, home: home) { $0 == "/Users/test/.local/bin/claude" }, "/Users/test/.local/bin/claude")
    }

    func testNothingInstalledReturnsNil() {
        XCTAssertNil(ClaudeCLILocator.resolve(override: nil, home: home) { _ in false })
    }
}
