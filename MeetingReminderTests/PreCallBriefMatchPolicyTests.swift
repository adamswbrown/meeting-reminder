import XCTest
@testable import MeetingReminder

private func match(userAttached: Bool) -> BriefMatch {
    BriefMatch(pageID: "p", pageURL: "https://notion.so/p", title: "Brief",
               matchedAt: Date(timeIntervalSince1970: 0), userAttached: userAttached)
}

final class PreCallBriefMatchPolicyTests: XCTestCase {

    // A manual attach is definitive — always reused, never re-matched over.
    func testUserAttachedMatchIsReused() {
        let m = match(userAttached: true)
        XCTAssertEqual(PreCallBriefService.reusableStoredMatch(m), m)
    }

    // An automatic match must be re-evaluated: the real brief may be written after the
    // first (wider-window / wrong-occurrence) guess was made.
    func testAutoMatchIsNotReused() {
        XCTAssertNil(PreCallBriefService.reusableStoredMatch(match(userAttached: false)))
    }

    func testNoStoredMatch() {
        XCTAssertNil(PreCallBriefService.reusableStoredMatch(nil))
    }
}
